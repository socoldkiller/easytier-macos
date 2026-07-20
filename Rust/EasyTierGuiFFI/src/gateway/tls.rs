use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
};

use arc_swap::ArcSwap;
use async_trait::async_trait;
use pingora::{
    listeners::{TlsAccept, TlsAcceptCallbacks},
    tls::{
        ext,
        pkey::{PKey, Private},
        ssl::{AlpnError, NameType, SslAcceptor, SslMethod, SslRef},
        x509::X509,
    },
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use x509_parser::{extensions::GeneralName, parse_x509_certificate};

use super::config::{ValidatedGatewayConfig, normalize_certificate_domain, normalize_domain};

const H2_PROTOCOL: &[u8] = b"h2";
const H1_PROTOCOL: &[u8] = b"http/1.1";

#[derive(Clone, Debug)]
pub struct CertificateMetadata {
    pub domains: Vec<String>,
    pub authority: String,
    pub not_before: OffsetDateTime,
    pub not_after: OffsetDateTime,
    pub not_before_rfc3339: String,
    pub not_after_rfc3339: String,
    pub leaf_der: Vec<u8>,
}

pub struct CertifiedMaterial {
    leaf: X509,
    intermediates: Vec<X509>,
    private_key: PKey<Private>,
    pub metadata: CertificateMetadata,
}

impl std::fmt::Debug for CertifiedMaterial {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CertifiedMaterial")
            .field("metadata", &self.metadata)
            .finish_non_exhaustive()
    }
}

impl CertifiedMaterial {
    #[cfg(test)]
    pub fn from_pem(
        certificate_chain_pem: &str,
        private_key_pem: &str,
        expected_domains: &[String],
    ) -> Result<Self, String> {
        Self::from_pem_with_authority(
            certificate_chain_pem,
            private_key_pem,
            expected_domains,
            "letsencrypt".to_string(),
        )
    }

    pub fn from_pem_with_authority(
        certificate_chain_pem: &str,
        private_key_pem: &str,
        expected_domains: &[String],
        authority: String,
    ) -> Result<Self, String> {
        let mut certificates = X509::stack_from_pem(certificate_chain_pem.as_bytes())
            .map_err(|error| format!("failed to parse certificate chain PEM: {error}"))?;
        if certificates.is_empty() {
            return Err("certificate chain is empty".to_string());
        }
        let leaf = certificates.remove(0);
        let private_key = PKey::private_key_from_pem(private_key_pem.as_bytes())
            .map_err(|error| format!("failed to parse certificate private key: {error}"))?;
        let public_key = leaf
            .public_key()
            .map_err(|error| format!("failed to read certificate public key: {error}"))?;
        if !public_key.public_eq(&private_key) {
            return Err("certificate private key does not match the leaf certificate".to_string());
        }

        let leaf_der = leaf
            .to_der()
            .map_err(|error| format!("failed to encode leaf certificate: {error}"))?;
        let (_, parsed) = parse_x509_certificate(&leaf_der)
            .map_err(|error| format!("failed to parse leaf certificate: {error}"))?;
        let san = parsed
            .subject_alternative_name()
            .map_err(|error| format!("invalid certificate SAN extension: {error}"))?
            .ok_or_else(|| "certificate does not contain a SAN extension".to_string())?;

        let mut domains = BTreeSet::new();
        for general_name in &san.value.general_names {
            if let GeneralName::DNSName(domain) = general_name {
                domains.insert(normalize_certificate_domain(domain)?);
            }
        }
        let expected = expected_domains
            .iter()
            .cloned()
            .collect::<BTreeSet<String>>();
        if domains != expected {
            return Err(format!(
                "certificate SAN set does not match configured domains: expected {expected:?}, got {domains:?}"
            ));
        }

        let not_before = parsed.validity().not_before.to_datetime();
        let not_after = parsed.validity().not_after.to_datetime();
        let now = OffsetDateTime::now_utc();
        if not_after <= now {
            return Err("certificate is already expired".to_string());
        }
        if not_before > now + time::Duration::minutes(5) {
            return Err("certificate is not valid yet".to_string());
        }

        let not_before_rfc3339 = not_before
            .format(&Rfc3339)
            .map_err(|error| format!("failed to format certificate not-before: {error}"))?;
        let not_after_rfc3339 = not_after
            .format(&Rfc3339)
            .map_err(|error| format!("failed to format certificate not-after: {error}"))?;

        Ok(Self {
            leaf,
            intermediates: certificates,
            private_key,
            metadata: CertificateMetadata {
                domains: domains.into_iter().collect(),
                authority,
                not_before,
                not_after,
                not_before_rfc3339,
                not_after_rfc3339,
                leaf_der,
            },
        })
    }

    fn apply_to(&self, ssl: &mut SslRef) -> Result<(), String> {
        ext::ssl_use_certificate(ssl, &self.leaf)
            .map_err(|error| format!("failed to select TLS certificate: {error}"))?;
        ext::ssl_use_private_key(ssl, &self.private_key)
            .map_err(|error| format!("failed to select TLS private key: {error}"))?;
        for certificate in &self.intermediates {
            ext::ssl_add_chain_cert(ssl, certificate)
                .map_err(|error| format!("failed to add TLS intermediate certificate: {error}"))?;
        }
        Ok(())
    }
}

pub struct DynamicCertificateStore {
    certificates: ArcSwap<BTreeMap<String, Arc<CertifiedMaterial>>>,
    sni_to_certificate: ArcSwap<BTreeMap<String, String>>,
    http_only_certificates: ArcSwap<BTreeSet<String>>,
    callback_error: Mutex<Option<String>>,
}

impl DynamicCertificateStore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            certificates: ArcSwap::from_pointee(BTreeMap::new()),
            sni_to_certificate: ArcSwap::from_pointee(BTreeMap::new()),
            http_only_certificates: ArcSwap::from_pointee(BTreeSet::new()),
            callback_error: Mutex::new(None),
        })
    }

    pub fn update_routes(&self, config: &ValidatedGatewayConfig) {
        let routes = config
            .routes
            .values()
            .map(|route| (route.domain.clone(), route.certificate_id.clone()))
            .collect();
        self.sni_to_certificate.store(Arc::new(routes));
    }

    pub fn install(&self, certificate_id: String, material: Arc<CertifiedMaterial>) {
        let mut certificates = self.certificates.load().as_ref().clone();
        certificates.insert(certificate_id.clone(), material);
        self.certificates.store(Arc::new(certificates));
        let mut http_only = self.http_only_certificates.load().as_ref().clone();
        http_only.remove(&certificate_id);
        self.http_only_certificates.store(Arc::new(http_only));
    }

    pub fn reconcile(&self, config: &ValidatedGatewayConfig) {
        let mut certificates = self.certificates.load().as_ref().clone();
        certificates.retain(|certificate_id, material| {
            config
                .certificates
                .get(certificate_id)
                .is_some_and(|certificate| certificate.domains == material.metadata.domains)
        });
        self.certificates.store(Arc::new(certificates));
        let mut http_only = self.http_only_certificates.load().as_ref().clone();
        http_only.retain(|certificate_id| config.certificates.contains_key(certificate_id));
        self.http_only_certificates.store(Arc::new(http_only));
    }

    pub fn mark_http_only(&self, certificate_id: &str) {
        let mut http_only = self.http_only_certificates.load().as_ref().clone();
        http_only.insert(certificate_id.to_string());
        self.http_only_certificates.store(Arc::new(http_only));
    }

    pub fn remove(&self, certificate_id: &str) {
        let mut certificates = self.certificates.load().as_ref().clone();
        certificates.remove(certificate_id);
        self.certificates.store(Arc::new(certificates));
    }

    pub fn is_http_only_for_domain(&self, domain: &str) -> bool {
        let Some(certificate_id) = self.sni_to_certificate.load().get(domain).cloned() else {
            return false;
        };
        self.http_only_certificates.load().contains(&certificate_id)
    }

    pub fn get(&self, certificate_id: &str) -> Option<Arc<CertifiedMaterial>> {
        self.certificates.load().get(certificate_id).cloned()
    }

    pub fn has_certificate_for_domain(&self, domain: &str) -> bool {
        let routes = self.sni_to_certificate.load();
        let certificates = self.certificates.load();
        routes
            .get(domain)
            .and_then(|certificate_id| certificates.get(certificate_id))
            .is_some()
    }

    pub fn callback_error(&self) -> Option<String> {
        self.callback_error
            .lock()
            .ok()
            .and_then(|error| error.clone())
    }

    fn set_callback_error(&self, error: impl Into<String>) {
        if let Ok(mut slot) = self.callback_error.lock() {
            *slot = Some(error.into());
        }
    }

    fn clear_callback_error(&self) {
        if let Ok(mut slot) = self.callback_error.lock() {
            *slot = None;
        }
    }
}

#[derive(Clone, Debug)]
pub struct SniConnectionInfo {
    pub server_name: String,
}

struct DynamicTlsCallback {
    store: Arc<DynamicCertificateStore>,
}

#[async_trait]
impl TlsAccept for DynamicTlsCallback {
    async fn certificate_callback(&self, ssl: &mut SslRef) {
        let Some(raw_sni) = ssl.servername(NameType::HOST_NAME) else {
            self.store
                .set_callback_error("TLS handshake did not include SNI");
            return;
        };
        let sni = match normalize_domain(raw_sni) {
            Ok(sni) => sni,
            Err(error) => {
                self.store.set_callback_error(error);
                return;
            }
        };

        let routes = self.store.sni_to_certificate.load();
        let Some(certificate_id) = routes.get(&sni) else {
            self.store
                .set_callback_error(format!("no gateway route for TLS SNI {sni}"));
            return;
        };
        let certificates = self.store.certificates.load();
        let Some(certificate) = certificates.get(certificate_id) else {
            self.store.set_callback_error(format!(
                "certificate {certificate_id} is not available for TLS SNI {sni}"
            ));
            return;
        };
        match certificate.apply_to(ssl) {
            Ok(()) => self.store.clear_callback_error(),
            Err(error) => self.store.set_callback_error(error),
        }
    }

    async fn handshake_complete_callback(
        &self,
        ssl: &SslRef,
    ) -> Option<Arc<dyn std::any::Any + Send + Sync>> {
        let server_name = normalize_domain(ssl.servername(NameType::HOST_NAME)?).ok()?;
        Some(Arc::new(SniConnectionInfo { server_name }))
    }
}

pub fn build_tls_acceptor(
    store: Arc<DynamicCertificateStore>,
) -> Result<(Arc<SslAcceptor>, Arc<TlsAcceptCallbacks>), String> {
    let mut builder = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls())
        .map_err(|error| format!("failed to create BoringSSL acceptor: {error}"))?;
    builder.set_alpn_select_callback(|_, offered| select_alpn(offered).ok_or(AlpnError::NOACK));
    let callbacks: TlsAcceptCallbacks = Box::new(DynamicTlsCallback { store });
    Ok((Arc::new(builder.build()), Arc::new(callbacks)))
}

fn select_alpn(offered: &[u8]) -> Option<&[u8]> {
    let mut protocols = offered;
    let mut h1 = None;
    while let Some((&length, rest)) = protocols.split_first() {
        let length = usize::from(length);
        if rest.len() < length {
            return None;
        }
        let (protocol, remaining) = rest.split_at(length);
        if protocol == H2_PROTOCOL {
            return Some(protocol);
        }
        if protocol == H1_PROTOCOL {
            h1 = Some(protocol);
        }
        protocols = remaining;
    }
    h1
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use rcgen::{CertificateParams, KeyPair};
    use serde_json::json;

    use super::*;
    use crate::gateway::config::GatewayConfig;

    #[test]
    fn alpn_prefers_h2_and_falls_back_to_h1() {
        assert_eq!(select_alpn(b"\x08http/1.1\x02h2"), Some(H2_PROTOCOL));
        assert_eq!(select_alpn(b"\x08http/1.1"), Some(H1_PROTOCOL));
        assert_eq!(select_alpn(b"\x03foo"), None);
    }

    #[test]
    fn certificate_installation_hot_swaps_material() {
        let store = DynamicCertificateStore::new();
        let first = test_material("app.example.com");
        let second = test_material("app.example.com");
        let first_leaf = first.metadata.leaf_der.clone();
        let second_leaf = second.metadata.leaf_der.clone();
        assert_ne!(first_leaf, second_leaf);

        store.install("app-cert".to_string(), first);
        assert_eq!(store.get("app-cert").unwrap().metadata.leaf_der, first_leaf);
        store.install("app-cert".to_string(), second);
        assert_eq!(
            store.get("app-cert").unwrap().metadata.leaf_der,
            second_leaf
        );
    }

    #[test]
    fn reconciliation_removes_material_for_changed_domains() {
        let store = DynamicCertificateStore::new();
        store.install("app-cert".to_string(), test_material("old.example.com"));
        let config = GatewayConfig::parse(
            &json!({
                "schema_version": 4,
                "storage_dir": PathBuf::from("/tmp/easytier-gateway-tls-test"),
                "listeners": {
                    "http": "127.0.0.1:5002",
                    "https": "127.0.0.1:8443",
                    "dns": "127.0.0.1:53535"
                },
                "local_dns": {
                    "domains": [],
                    "answer_ipv4": "127.0.0.1",
                    "ttl": 30
                },
                "acme": {
                    "directory": { "kind": "letsencrypt_staging" },
                    "contact_email": "gateway@example.com",
                    "terms_of_service_agreed": true
                },
                "certificates": [{
                    "id": "app-cert",
                    "domains": ["new.example.com"],
                    "challenge": { "type": "http01" }
                }],
                "routes": []
            })
            .to_string(),
        )
        .unwrap()
        .validate()
        .unwrap();

        store.reconcile(&config);
        assert!(store.get("app-cert").is_none());
    }

    fn test_material(domain: &str) -> Arc<CertifiedMaterial> {
        let mut params = CertificateParams::new(vec![domain.to_string()]).unwrap();
        params.not_before = OffsetDateTime::now_utc() - time::Duration::days(1);
        params.not_after = OffsetDateTime::now_utc() + time::Duration::days(90);
        let key = KeyPair::generate().unwrap();
        let certificate = params.self_signed(&key).unwrap();
        Arc::new(
            CertifiedMaterial::from_pem(
                &certificate.pem(),
                &key.serialize_pem(),
                &[domain.to_string()],
            )
            .unwrap(),
        )
    }
}
