use std::{path::PathBuf, sync::Arc, time::Duration};

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
    config::{AcmeConfig, AcmeDirectoryConfig},
    storage::GatewayStorage,
};

const ZEROSSL_DIRECTORY_URL: &str = "https://acme.zerossl.com/v2/DV90";
const ZEROSSL_EAB_URL: &str = "https://api.zerossl.com/acme/eab-credentials-email";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthorityKind {
    LetsEncrypt,
    ZeroSsl,
}

impl AuthorityKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::LetsEncrypt => "Let's Encrypt",
            Self::ZeroSsl => "ZeroSSL",
        }
    }

    pub fn storage_value(self) -> &'static str {
        match self {
            Self::LetsEncrypt => "letsencrypt",
            Self::ZeroSsl => "zerossl",
        }
    }

    pub fn from_storage(value: &str) -> Self {
        match value {
            "zerossl" => Self::ZeroSsl,
            _ => Self::LetsEncrypt,
        }
    }
}

#[async_trait]
trait CertificateAuthorityProvider: Send + Sync {
    fn kind(&self) -> AuthorityKind;

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
    pub fn production(config: &AcmeConfig) -> Self {
        Self {
            providers: vec![
                Arc::new(LetsEncryptProvider::new(config.directory.clone())),
                Arc::new(ZeroSslProvider::new()),
            ],
        }
    }

    #[cfg(test)]
    pub fn testing(config: &AcmeConfig, http: Box<dyn HttpClient>) -> Self {
        Self {
            providers: vec![Arc::new(LetsEncryptProvider::new_with_http(
                config.directory.clone(),
                http,
            ))],
        }
    }

    pub fn ordered_kinds(&self) -> Vec<AuthorityKind> {
        self.providers
            .iter()
            .map(|provider| provider.kind())
            .collect()
    }

    pub async fn account(
        &self,
        kind: AuthorityKind,
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
            provider.update_contacts(contacts).await.map_err(|_| {
                "failed to update automatic certificate account contact".to_string()
            })?;
        }
        Ok(())
    }
}

struct LetsEncryptProvider {
    directory_url: String,
    custom_root: Option<PathBuf>,
    account: OnceCell<Account>,
    #[cfg(test)]
    test_http: Mutex<Option<Box<dyn HttpClient>>>,
}

impl LetsEncryptProvider {
    fn new(directory: AcmeDirectoryConfig) -> Self {
        Self {
            directory_url: directory.url().to_string(),
            custom_root: directory.custom_ca_cert_path().cloned(),
            account: OnceCell::new(),
            #[cfg(test)]
            test_http: Mutex::new(None),
        }
    }

    #[cfg(test)]
    fn new_with_http(directory: AcmeDirectoryConfig, http: Box<dyn HttpClient>) -> Self {
        Self {
            directory_url: directory.url().to_string(),
            custom_root: directory.custom_ca_cert_path().cloned(),
            account: OnceCell::new(),
            test_http: Mutex::new(Some(http)),
        }
    }

    async fn builder(&self) -> Result<AccountBuilder, String> {
        #[cfg(test)]
        if let Some(http) = self.test_http.lock().await.take() {
            return Ok(Account::builder_with_http(http));
        }

        match &self.custom_root {
            Some(path) => Account::builder_with_root(path)
                .map_err(|error| format!("failed to configure custom ACME CA: {error}")),
            None => Account::builder()
                .map_err(|error| format!("failed to create ACME HTTP client: {error}")),
        }
    }
}

#[async_trait]
impl CertificateAuthorityProvider for LetsEncryptProvider {
    fn kind(&self) -> AuthorityKind {
        AuthorityKind::LetsEncrypt
    }

    async fn account(
        &self,
        config: &AcmeConfig,
        storage: &GatewayStorage,
    ) -> Result<Account, String> {
        self.account
            .get_or_try_init(|| async {
                let builder = self.builder().await?;
                if let Some(credentials) = storage.load_account(&self.directory_url)? {
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
                        self.directory_url.clone(),
                        None,
                    )
                    .await
                    .map_err(|error| format!("failed to create ACME account: {error}"))?;
                storage.store_account(&self.directory_url, &credentials)?;
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
    fn kind(&self) -> AuthorityKind {
        AuthorityKind::ZeroSsl
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
    use super::*;

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
}
