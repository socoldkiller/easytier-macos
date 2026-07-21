use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use base64::{
    Engine as _,
    engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD},
};
#[cfg(test)]
use instant_acme::HttpClient;
use instant_acme::{Account, AccountBuilder, ExternalAccountKey, NewAccount};
use serde::Deserialize;
#[cfg(test)]
use tokio::sync::Mutex;
use tokio::sync::OnceCell;

use super::{
    config::{AcmeConfig, CertificateAuthorityKind},
    storage::GatewayStorage,
};

const ZEROSSL_DIRECTORY_URL: &str = "https://acme.zerossl.com/v2/DV90";
const ZEROSSL_EAB_URL: &str = "https://api.zerossl.com/acme/eab-credentials-email";
const LETSENCRYPT_DIRECTORY_URL: &str = "https://acme-v02.api.letsencrypt.org/directory";

impl CertificateAuthorityKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Letsencrypt => "Let's Encrypt",
            Self::Zerossl => "ZeroSSL",
        }
    }
}

#[async_trait]
trait CertificateAuthorityProvider: Send + Sync {
    fn kind(&self) -> CertificateAuthorityKind;

    async fn account(
        &self,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String>;

    async fn update_contacts(&self, contacts: &[&str]) -> Result<(), String>;
}

pub struct AuthorityPool {
    providers: Vec<Arc<dyn CertificateAuthorityProvider>>,
}

impl AuthorityPool {
    pub fn production() -> Self {
        Self {
            providers: vec![
                Arc::new(LetsEncryptProvider::new()),
                Arc::new(ZeroSslProvider::new()),
            ],
        }
    }

    #[cfg(test)]
    pub fn testing(kind: CertificateAuthorityKind, http: Box<dyn HttpClient>) -> Self {
        Self {
            providers: vec![Arc::new(TestAuthorityProvider::new(kind, http))],
        }
    }

    pub async fn account(
        &self,
        kind: CertificateAuthorityKind,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String> {
        let provider = self
            .providers
            .iter()
            .find(|provider| provider.kind() == kind)
            .ok_or_else(|| format!("certificate authority {kind:?} is unavailable"))?;
        provider.account(config, storage).await
    }

    pub async fn update_contacts(&self, contacts: &[&str]) -> Result<(), String> {
        for provider in &self.providers {
            provider
                .update_contacts(contacts)
                .await
                .map_err(|_| "failed to update certificate account contact".to_string())?;
        }
        Ok(())
    }
}

#[cfg(test)]
struct TestAuthorityProvider {
    kind: CertificateAuthorityKind,
    account: OnceCell<Account>,
    http: Mutex<Option<Box<dyn HttpClient>>>,
}

#[cfg(test)]
impl TestAuthorityProvider {
    fn new(kind: CertificateAuthorityKind, http: Box<dyn HttpClient>) -> Self {
        Self {
            kind,
            account: OnceCell::new(),
            http: Mutex::new(Some(http)),
        }
    }
}

#[cfg(test)]
#[async_trait]
impl CertificateAuthorityProvider for TestAuthorityProvider {
    fn kind(&self) -> CertificateAuthorityKind {
        self.kind
    }

    async fn account(
        &self,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String> {
        self.account
            .get_or_try_init(|| async {
                let http = self
                    .http
                    .lock()
                    .await
                    .take()
                    .ok_or_else(|| "test ACME HTTP client was already consumed".to_string())?;
                let builder = Account::builder_with_http(http);
                let directory_url = match self.kind {
                    CertificateAuthorityKind::Letsencrypt => LETSENCRYPT_DIRECTORY_URL,
                    CertificateAuthorityKind::Zerossl => ZEROSSL_DIRECTORY_URL,
                };
                if let Some(credentials) = storage.load_account(directory_url)? {
                    return builder
                        .from_credentials(credentials)
                        .await
                        .map_err(|error| format!("failed to restore test ACME account: {error}"));
                }

                let contact = config
                    .contact_email
                    .as_deref()
                    .map(|email| format!("mailto:{email}"));
                let contacts = contact.as_deref().into_iter().collect::<Vec<_>>();
                let (account, credentials) = builder
                    .create(
                        &NewAccount {
                            contact: &contacts,
                            terms_of_service_agreed: config.terms_of_service_agreed,
                            only_return_existing: false,
                        },
                        directory_url.to_string(),
                        None,
                    )
                    .await
                    .map_err(|error| format!("failed to create test ACME account: {error}"))?;
                storage.store_account(directory_url, &credentials)?;
                Ok(account)
            })
            .await
            .cloned()
    }

    async fn update_contacts(&self, contacts: &[&str]) -> Result<(), String> {
        let Some(account) = self.account.get() else {
            return Ok(());
        };
        account
            .update_contacts(contacts)
            .await
            .map_err(|error| format!("failed to update test ACME account contact: {error}"))
    }
}

struct LetsEncryptProvider {
    account: OnceCell<Account>,
}

impl LetsEncryptProvider {
    fn new() -> Self {
        Self {
            account: OnceCell::new(),
        }
    }

    async fn builder(&self) -> Result<AccountBuilder, String> {
        Account::builder().map_err(|error| format!("failed to create ACME HTTP client: {error}"))
    }
}

#[async_trait]
impl CertificateAuthorityProvider for LetsEncryptProvider {
    fn kind(&self) -> CertificateAuthorityKind {
        CertificateAuthorityKind::Letsencrypt
    }

    async fn account(
        &self,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String> {
        self.account
            .get_or_try_init(|| async {
                let builder = self.builder().await?;
                if let Some(credentials) = storage.load_account(LETSENCRYPT_DIRECTORY_URL)? {
                    return builder
                        .from_credentials(credentials)
                        .await
                        .map_err(|error| format!("failed to restore ACME account: {error}"));
                }

                let contact = config
                    .contact_email
                    .as_deref()
                    .map(|email| format!("mailto:{email}"));
                let contacts = contact.as_deref().into_iter().collect::<Vec<_>>();
                let (account, credentials) = builder
                    .create(
                        &NewAccount {
                            contact: &contacts,
                            terms_of_service_agreed: config.terms_of_service_agreed,
                            only_return_existing: false,
                        },
                        LETSENCRYPT_DIRECTORY_URL.to_string(),
                        None,
                    )
                    .await
                    .map_err(|error| format!("failed to create ACME account: {error}"))?;
                storage.store_account(LETSENCRYPT_DIRECTORY_URL, &credentials)?;
                Ok(account)
            })
            .await
            .cloned()
    }

    async fn update_contacts(&self, contacts: &[&str]) -> Result<(), String> {
        let Some(account) = self.account.get() else {
            return Ok(());
        };
        account
            .update_contacts(contacts)
            .await
            .map_err(|error| format!("failed to update ACME account contact: {error}"))
    }
}

struct ZeroSslProvider {
    account: OnceCell<Account>,
    http: Result<reqwest::Client, String>,
}

impl ZeroSslProvider {
    fn new() -> Self {
        Self {
            account: OnceCell::new(),
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build()
                .map_err(|error| format!("failed to create EAB HTTP client: {error}")),
        }
    }

    async fn external_account_key(&self, email: &str) -> Result<ExternalAccountKey, String> {
        let body = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("email", email)
            .finish();
        let client = self.http.as_ref().map_err(Clone::clone)?;
        let response = client
            .post(ZEROSSL_EAB_URL)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body)
            .send()
            .await
            .map_err(|error| format!("ZeroSSL EAB request failed: {error}"))?;
        if !response.status().is_success() {
            return Err(format!(
                "ZeroSSL EAB request returned HTTP {}",
                response.status()
            ));
        }
        let payload: ZeroSslEabResponse = response
            .json()
            .await
            .map_err(|error| format!("ZeroSSL EAB response was invalid: {error}"))?;
        external_account_key_from_response(payload)
    }
}

#[async_trait]
impl CertificateAuthorityProvider for ZeroSslProvider {
    fn kind(&self) -> CertificateAuthorityKind {
        CertificateAuthorityKind::Zerossl
    }

    async fn account(
        &self,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String> {
        self.account
            .get_or_try_init(|| async {
                let builder = Account::builder()
                    .map_err(|error| format!("failed to create ZeroSSL ACME client: {error}"))?;
                if let Some(credentials) = storage.load_account(ZEROSSL_DIRECTORY_URL)? {
                    return builder
                        .from_credentials(credentials)
                        .await
                        .map_err(|error| format!("failed to restore ZeroSSL account: {error}"));
                }

                let email = config
                    .contact_email
                    .as_deref()
                    .ok_or_else(|| "certificate contact email is required".to_string())?;
                let external_account = self.external_account_key(email).await?;
                let contact = config
                    .contact_email
                    .as_deref()
                    .map(|email| format!("mailto:{email}"));
                let contacts = contact.as_deref().into_iter().collect::<Vec<_>>();
                let (account, credentials) = builder
                    .create(
                        &NewAccount {
                            contact: &contacts,
                            terms_of_service_agreed: config.terms_of_service_agreed,
                            only_return_existing: false,
                        },
                        ZEROSSL_DIRECTORY_URL.to_string(),
                        Some(&external_account),
                    )
                    .await
                    .map_err(|error| format!("failed to create ZeroSSL ACME account: {error}"))?;
                storage.store_account(ZEROSSL_DIRECTORY_URL, &credentials)?;
                Ok(account)
            })
            .await
            .cloned()
    }

    async fn update_contacts(&self, contacts: &[&str]) -> Result<(), String> {
        let Some(account) = self.account.get() else {
            return Ok(());
        };
        account
            .update_contacts(contacts)
            .await
            .map_err(|error| format!("failed to update ZeroSSL account contact: {error}"))
    }
}

#[derive(Deserialize)]
struct ZeroSslEabResponse {
    eab_kid: String,
    eab_hmac_key: String,
}

fn external_account_key_from_response(
    payload: ZeroSslEabResponse,
) -> Result<ExternalAccountKey, String> {
    if payload.eab_kid.trim().is_empty() || payload.eab_hmac_key.trim().is_empty() {
        return Err("ZeroSSL EAB response did not contain credentials".to_string());
    }
    let key = URL_SAFE_NO_PAD
        .decode(payload.eab_hmac_key.as_bytes())
        .or_else(|_| URL_SAFE.decode(payload.eab_hmac_key.as_bytes()))
        .map_err(|_| "ZeroSSL EAB HMAC key was not valid URL-safe Base64".to_string())?;
    Ok(ExternalAccountKey::new(payload.eab_kid, &key))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    struct FailingAuthorityProvider {
        kind: CertificateAuthorityKind,
        calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl CertificateAuthorityProvider for FailingAuthorityProvider {
        fn kind(&self) -> CertificateAuthorityKind {
            self.kind
        }

        async fn account(
            &self,
            _config: &AcmeConfig,
            _storage: &GatewayStorage,
        ) -> Result<Account, String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Err(format!("{} was selected", self.kind.display_name()))
        }

        async fn update_contacts(&self, _contacts: &[&str]) -> Result<(), String> {
            Ok(())
        }
    }

    #[test]
    fn eab_response_accepts_padded_and_unpadded_url_safe_base64() {
        for hmac_key in ["c2VjcmU", "c2VjcmU="] {
            assert!(
                external_account_key_from_response(ZeroSslEabResponse {
                    eab_kid: "kid".to_string(),
                    eab_hmac_key: hmac_key.to_string(),
                })
                .is_ok()
            );
        }
    }

    #[test]
    fn eab_response_rejects_missing_or_malformed_credentials() {
        assert!(
            external_account_key_from_response(ZeroSslEabResponse {
                eab_kid: String::new(),
                eab_hmac_key: "c2VjcmV0".to_string(),
            })
            .is_err()
        );
        assert!(
            external_account_key_from_response(ZeroSslEabResponse {
                eab_kid: "kid".to_string(),
                eab_hmac_key: "not base64!".to_string(),
            })
            .is_err()
        );
    }

    #[test]
    fn authority_pool_only_calls_the_selected_provider() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            for selected in [
                CertificateAuthorityKind::Letsencrypt,
                CertificateAuthorityKind::Zerossl,
            ] {
                let letsencrypt_calls = Arc::new(AtomicUsize::new(0));
                let zerossl_calls = Arc::new(AtomicUsize::new(0));
                let pool = AuthorityPool {
                    providers: vec![
                        Arc::new(FailingAuthorityProvider {
                            kind: CertificateAuthorityKind::Letsencrypt,
                            calls: letsencrypt_calls.clone(),
                        }),
                        Arc::new(FailingAuthorityProvider {
                            kind: CertificateAuthorityKind::Zerossl,
                            calls: zerossl_calls.clone(),
                        }),
                    ],
                };
                let temp = tempfile::tempdir().unwrap();
                let storage = GatewayStorage::initialize(temp.path().join("gateway")).unwrap();
                let result = pool
                    .account(
                        selected,
                        &AcmeConfig {
                            contact_email: Some("ops@example.com".to_string()),
                            terms_of_service_agreed: true,
                        },
                        &storage,
                    )
                    .await;
                let error = match result {
                    Ok(_) => panic!("the failing provider unexpectedly returned an account"),
                    Err(error) => error,
                };

                assert!(error.contains(selected.display_name()));
                assert_eq!(
                    letsencrypt_calls.load(Ordering::SeqCst),
                    usize::from(selected == CertificateAuthorityKind::Letsencrypt)
                );
                assert_eq!(
                    zerossl_calls.load(Ordering::SeqCst),
                    usize::from(selected == CertificateAuthorityKind::Zerossl)
                );
            }
        });
    }
}
