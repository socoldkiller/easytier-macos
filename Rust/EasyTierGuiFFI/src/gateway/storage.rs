use std::{
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use instant_acme::AccountCredentials;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::tls::CertifiedMaterial;

const DIRECTORY_MODE: u32 = 0o700;
const FILE_MODE: u32 = 0o600;

#[derive(Clone, Debug)]
pub struct GatewayStorage {
    root: PathBuf,
    cleanup_journal_lock: Arc<Mutex<()>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredCertificateMetadata {
    domains: Vec<String>,
    chain_sha256: String,
    key_sha256: String,
    #[serde(default = "default_certificate_authority")]
    authority: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct PendingDnsCleanup {
    pub provider: String,
    pub credential_id: String,
    pub zone_id: String,
    pub record_id: String,
    pub record_name: String,
}

impl GatewayStorage {
    pub fn initialize(root: PathBuf) -> Result<Self, String> {
        create_private_directory(&root)?;
        create_private_directory(&root.join("accounts"))?;
        create_private_directory(&root.join("certificates"))?;
        Ok(Self {
            root,
            cleanup_journal_lock: Arc::new(Mutex::new(())),
        })
    }

    pub fn load_account(&self, directory_url: &str) -> Result<Option<AccountCredentials>, String> {
        let path = self.account_path(directory_url);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "failed to read ACME account credentials {}: {error}",
                    path.display()
                ));
            }
        };
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| format!("failed to decode ACME account credentials: {error}"))
    }

    pub fn store_account(
        &self,
        directory_url: &str,
        credentials: &AccountCredentials,
    ) -> Result<(), String> {
        let path = self.account_path(directory_url);
        let bytes = serde_json::to_vec_pretty(credentials)
            .map_err(|error| format!("failed to encode ACME account credentials: {error}"))?;
        write_atomic(&path, &bytes)
    }

    pub fn load_certificate(
        &self,
        certificate_id: &str,
        expected_domains: &[String],
    ) -> Result<Option<Arc<CertifiedMaterial>>, String> {
        let directory = self.certificate_directory(certificate_id);
        let metadata_path = directory.join("metadata.json");
        let metadata_bytes = match fs::read(&metadata_path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "failed to read certificate metadata {}: {error}",
                    metadata_path.display()
                ));
            }
        };
        let metadata: StoredCertificateMetadata = serde_json::from_slice(&metadata_bytes)
            .map_err(|error| format!("failed to decode certificate metadata: {error}"))?;
        if metadata.domains != expected_domains {
            return Ok(None);
        }

        let chain_path = directory.join("chain.pem");
        let key_path = directory.join("key.pem");
        let chain = fs::read_to_string(&chain_path).map_err(|error| {
            format!(
                "failed to read certificate chain {}: {error}",
                chain_path.display()
            )
        })?;
        let key = fs::read_to_string(&key_path).map_err(|error| {
            format!(
                "failed to read certificate private key {}: {error}",
                key_path.display()
            )
        })?;
        if sha256_hex(chain.as_bytes()) != metadata.chain_sha256
            || sha256_hex(key.as_bytes()) != metadata.key_sha256
        {
            return Err(format!(
                "stored certificate {certificate_id} failed integrity validation"
            ));
        }

        CertifiedMaterial::from_pem_with_authority(
            &chain,
            &key,
            expected_domains,
            metadata.authority,
        )
        .map(|material| Some(Arc::new(material)))
    }

    pub fn store_certificate(
        &self,
        certificate_id: &str,
        domains: &[String],
        certificate_chain_pem: &str,
        private_key_pem: &str,
        authority: &str,
    ) -> Result<Arc<CertifiedMaterial>, String> {
        let material = Arc::new(CertifiedMaterial::from_pem_with_authority(
            certificate_chain_pem,
            private_key_pem,
            domains,
            authority.to_string(),
        )?);
        let directory = self.certificate_directory(certificate_id);
        create_private_directory(&directory)?;

        let metadata = StoredCertificateMetadata {
            domains: domains.to_vec(),
            chain_sha256: sha256_hex(certificate_chain_pem.as_bytes()),
            key_sha256: sha256_hex(private_key_pem.as_bytes()),
            authority: authority.to_string(),
        };
        let metadata_bytes = serde_json::to_vec_pretty(&metadata)
            .map_err(|error| format!("failed to encode certificate metadata: {error}"))?;

        write_atomic(
            &directory.join("chain.pem"),
            certificate_chain_pem.as_bytes(),
        )?;
        write_atomic(&directory.join("key.pem"), private_key_pem.as_bytes())?;
        // Metadata is the commit marker and is written only after both PEM files are durable.
        write_atomic(&directory.join("metadata.json"), &metadata_bytes)?;
        Ok(material)
    }

    pub fn load_cleanup_journal(&self) -> Result<Vec<PendingDnsCleanup>, String> {
        let _guard = self
            .cleanup_journal_lock
            .lock()
            .map_err(|_| "DNS cleanup journal lock is poisoned".to_string())?;
        self.load_cleanup_journal_unlocked()
    }

    pub fn store_cleanup_journal(&self, pending: &[PendingDnsCleanup]) -> Result<(), String> {
        let _guard = self
            .cleanup_journal_lock
            .lock()
            .map_err(|_| "DNS cleanup journal lock is poisoned".to_string())?;
        self.store_cleanup_journal_unlocked(pending)
    }

    pub fn merge_cleanup_journal(
        &self,
        additions: &[PendingDnsCleanup],
    ) -> Result<Vec<PendingDnsCleanup>, String> {
        let _guard = self
            .cleanup_journal_lock
            .lock()
            .map_err(|_| "DNS cleanup journal lock is poisoned".to_string())?;
        let mut pending = self.load_cleanup_journal_unlocked()?;
        for cleanup in additions {
            if !pending.contains(cleanup) {
                pending.push(cleanup.clone());
            }
        }
        self.store_cleanup_journal_unlocked(&pending)?;
        Ok(pending)
    }

    pub fn complete_cleanup_attempt(
        &self,
        attempted: &[PendingDnsCleanup],
        remaining: &[PendingDnsCleanup],
    ) -> Result<Vec<PendingDnsCleanup>, String> {
        let _guard = self
            .cleanup_journal_lock
            .lock()
            .map_err(|_| "DNS cleanup journal lock is poisoned".to_string())?;
        let mut pending = self.load_cleanup_journal_unlocked()?;
        pending.retain(|cleanup| !attempted.contains(cleanup));
        for cleanup in remaining {
            if !pending.contains(cleanup) {
                pending.push(cleanup.clone());
            }
        }
        self.store_cleanup_journal_unlocked(&pending)?;
        Ok(pending)
    }

    fn load_cleanup_journal_unlocked(&self) -> Result<Vec<PendingDnsCleanup>, String> {
        let path = self.cleanup_journal_path();
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(format!(
                    "failed to read DNS cleanup journal {}: {error}",
                    path.display()
                ));
            }
        };
        serde_json::from_slice(&bytes)
            .map_err(|error| format!("failed to decode DNS cleanup journal: {error}"))
    }

    fn store_cleanup_journal_unlocked(&self, pending: &[PendingDnsCleanup]) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(pending)
            .map_err(|error| format!("failed to encode DNS cleanup journal: {error}"))?;
        write_atomic(&self.cleanup_journal_path(), &bytes)
    }

    fn account_path(&self, directory_url: &str) -> PathBuf {
        self.root
            .join("accounts")
            .join(format!("{}.json", sha256_hex(directory_url.as_bytes())))
    }

    fn certificate_directory(&self, certificate_id: &str) -> PathBuf {
        self.root.join("certificates").join(certificate_id)
    }

    fn cleanup_journal_path(&self) -> PathBuf {
        self.root.join("dns-cleanup-journal.json")
    }
}

fn default_certificate_authority() -> String {
    "letsencrypt".to_string()
}

fn create_private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path)
        .map_err(|error| format!("failed to create directory {}: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(DIRECTORY_MODE)).map_err(|error| {
        format!(
            "failed to set directory permissions for {}: {error}",
            path.display()
        )
    })
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("path has no parent: {}", path.display()))?;
    create_private_directory(parent)?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("path has an invalid file name: {}", path.display()))?;
    let temporary = parent.join(format!(".{file_name}.{}.tmp", uuid::Uuid::new_v4()));

    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(FILE_MODE)
            .open(&temporary)
            .map_err(|error| {
                format!(
                    "failed to create temporary file {}: {error}",
                    temporary.display()
                )
            })?;
        file.write_all(bytes).map_err(|error| {
            format!(
                "failed to write temporary file {}: {error}",
                temporary.display()
            )
        })?;
        file.sync_all().map_err(|error| {
            format!(
                "failed to sync temporary file {}: {error}",
                temporary.display()
            )
        })?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(FILE_MODE)).map_err(
            |error| {
                format!(
                    "failed to set file permissions for {}: {error}",
                    temporary.display()
                )
            },
        )?;
        fs::rename(&temporary, path).map_err(|error| {
            format!(
                "failed to replace file {} atomically: {error}",
                path.display()
            )
        })?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("failed to sync directory {}: {error}", parent.display()))
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn cleanup(record_id: &str) -> PendingDnsCleanup {
        PendingDnsCleanup {
            provider: "cloudflare".to_string(),
            credential_id: "cf-main".to_string(),
            zone_id: "zone".to_string(),
            record_id: record_id.to_string(),
            record_name: format!("_acme-challenge.{record_id}.example.com"),
        }
    }

    #[test]
    fn cleanup_journal_round_trips() {
        let directory = tempfile::tempdir().unwrap();
        let storage = GatewayStorage::initialize(directory.path().join("gateway")).unwrap();
        let pending = vec![cleanup("record")];
        storage.store_cleanup_journal(&pending).unwrap();
        assert_eq!(storage.load_cleanup_journal().unwrap(), pending);
    }

    #[test]
    fn cleanup_completion_preserves_records_added_during_retry() {
        let directory = tempfile::tempdir().unwrap();
        let storage = GatewayStorage::initialize(directory.path().join("gateway")).unwrap();
        let first = cleanup("first");
        let second = cleanup("second");
        let added_later = cleanup("added-later");
        let attempted = vec![first.clone(), second.clone()];
        storage.store_cleanup_journal(&attempted).unwrap();
        storage
            .merge_cleanup_journal(std::slice::from_ref(&added_later))
            .unwrap();

        let pending = storage
            .complete_cleanup_attempt(&attempted, std::slice::from_ref(&second))
            .unwrap();
        assert_eq!(pending.len(), 2);
        assert!(pending.contains(&second));
        assert!(pending.contains(&added_later));
        assert!(!pending.contains(&first));
    }

    #[test]
    fn storage_uses_private_permissions() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("gateway");
        let storage = GatewayStorage::initialize(root.clone()).unwrap();
        storage
            .store_cleanup_journal(std::slice::from_ref(&cleanup("record")))
            .unwrap();

        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(root.join("dns-cleanup-journal.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
