use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, SocketAddr},
    path::PathBuf,
};

use http::HeaderValue;
use serde::{Deserialize, Serialize};
use url::{Host, Url};

pub const GATEWAY_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GatewayConfig {
    pub schema_version: u32,
    pub storage_dir: PathBuf,
    pub listeners: ListenerConfig,
    pub acme: AcmeConfig,
    #[serde(default)]
    pub certificates: Vec<CertificateConfig>,
    #[serde(default)]
    pub routes: Vec<RouteConfig>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ListenerConfig {
    pub http: String,
    pub https: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AcmeConfig {
    #[serde(default)]
    pub directory: AcmeDirectoryConfig,
    pub contact_email: Option<String>,
    pub terms_of_service_agreed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AcmeDirectoryConfig {
    LetsencryptStaging,
    LetsencryptProduction,
    Custom { url: String, ca_cert_path: PathBuf },
}

impl Default for AcmeDirectoryConfig {
    fn default() -> Self {
        Self::LetsencryptStaging
    }
}

impl AcmeDirectoryConfig {
    pub fn url(&self) -> &str {
        match self {
            Self::LetsencryptStaging => instant_acme::LetsEncrypt::Staging.url(),
            Self::LetsencryptProduction => instant_acme::LetsEncrypt::Production.url(),
            Self::Custom { url, .. } => url,
        }
    }

    pub fn custom_ca_cert_path(&self) -> Option<&PathBuf> {
        match self {
            Self::Custom { ca_cert_path, .. } => Some(ca_cert_path),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CertificateConfig {
    pub id: String,
    pub domains: Vec<String>,
    pub challenge: ChallengeConfig,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ChallengeConfig {
    Http01,
    Dns01 {
        provider: DnsProviderKind,
        credential_id: String,
    },
}

impl ChallengeConfig {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Http01 => "http01",
            Self::Dns01 { .. } => "dns01",
        }
    }

    pub fn credential_id(&self) -> Option<&str> {
        match self {
            Self::Http01 => None,
            Self::Dns01 { credential_id, .. } => Some(credential_id),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DnsProviderKind {
    Cloudflare,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RouteConfig {
    pub domain: String,
    pub certificate_id: String,
    pub upstream: UpstreamConfig,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UpstreamConfig {
    pub url: String,
    pub host_header: Option<String>,
    pub tls_server_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GatewaySecrets {
    pub schema_version: u32,
    #[serde(default)]
    pub cloudflare: BTreeMap<String, CloudflareSecret>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloudflareSecret {
    pub api_token: String,
}

#[derive(Clone, Debug)]
pub struct ValidatedGatewayConfig {
    pub source: GatewayConfig,
    pub http_addr: SocketAddr,
    pub https_addr: SocketAddr,
    pub certificates: BTreeMap<String, ValidatedCertificate>,
    pub routes: BTreeMap<String, ValidatedRoute>,
}

#[derive(Clone, Debug)]
pub struct ValidatedCertificate {
    pub id: String,
    pub domains: Vec<String>,
    pub challenge: ChallengeConfig,
}

#[derive(Clone, Debug)]
pub struct ValidatedRoute {
    pub domain: String,
    pub certificate_id: String,
    pub upstream: ParsedUpstream,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpstreamScheme {
    Http,
    Https,
}

#[derive(Clone, Debug)]
pub struct ParsedUpstream {
    pub original_url: String,
    pub scheme: UpstreamScheme,
    pub host: String,
    pub port: u16,
    pub host_header: Option<String>,
    pub tls_server_name: Option<String>,
}

impl GatewayConfig {
    pub fn parse(json: &str) -> Result<Self, String> {
        serde_json::from_str(json).map_err(|error| format!("invalid gateway config JSON: {error}"))
    }

    pub fn validate(self) -> Result<ValidatedGatewayConfig, String> {
        if self.schema_version != GATEWAY_SCHEMA_VERSION {
            return Err(format!(
                "unsupported gateway config schema_version {}; expected {GATEWAY_SCHEMA_VERSION}",
                self.schema_version
            ));
        }
        if !self.storage_dir.is_absolute() {
            return Err("storage_dir must be an absolute path".to_string());
        }
        if !self.acme.terms_of_service_agreed {
            return Err("acme.terms_of_service_agreed must be true".to_string());
        }
        if let Some(email) = self.acme.contact_email.as_deref() {
            validate_email(email)?;
        }
        validate_acme_directory(&self.acme.directory)?;

        let http_addr = parse_listener(&self.listeners.http, "listeners.http")?;
        let https_addr = parse_listener(&self.listeners.https, "listeners.https")?;
        if http_addr == https_addr && http_addr.port() != 0 {
            return Err("HTTP and HTTPS listeners must use different addresses".to_string());
        }

        let mut certificates = BTreeMap::new();
        for certificate in &self.certificates {
            validate_identifier(&certificate.id, "certificate id")?;
            if certificate.domains.is_empty() {
                return Err(format!(
                    "certificate {} must contain at least one domain",
                    certificate.id
                ));
            }

            let mut domains = Vec::with_capacity(certificate.domains.len());
            let mut seen_domains = BTreeSet::new();
            for domain in &certificate.domains {
                let domain = normalize_certificate_domain(domain)?;
                if !seen_domains.insert(domain.clone()) {
                    return Err(format!(
                        "certificate {} contains duplicate domain {domain}",
                        certificate.id
                    ));
                }
                domains.push(domain);
            }
            domains.sort();

            match &certificate.challenge {
                ChallengeConfig::Http01
                    if domains.iter().any(|domain| domain.starts_with("*.")) =>
                {
                    return Err(format!(
                        "certificate {} uses HTTP-01 but contains a wildcard domain",
                        certificate.id
                    ));
                }
                ChallengeConfig::Dns01 { credential_id, .. } => {
                    validate_identifier(credential_id, "credential id")?;
                }
                ChallengeConfig::Http01 => {}
            }

            let validated = ValidatedCertificate {
                id: certificate.id.clone(),
                domains,
                challenge: certificate.challenge.clone(),
            };
            if certificates
                .insert(certificate.id.clone(), validated)
                .is_some()
            {
                return Err(format!("duplicate certificate id {}", certificate.id));
            }
        }

        let mut routes = BTreeMap::new();
        for route in &self.routes {
            let domain = normalize_domain(&route.domain)?;
            let certificate = certificates.get(&route.certificate_id).ok_or_else(|| {
                format!(
                    "route {domain} references unknown certificate {}",
                    route.certificate_id
                )
            })?;
            if !certificate
                .domains
                .iter()
                .any(|pattern| certificate_domain_covers(pattern, &domain))
            {
                return Err(format!(
                    "certificate {} does not cover route domain {domain}",
                    certificate.id
                ));
            }

            let validated = ValidatedRoute {
                domain: domain.clone(),
                certificate_id: route.certificate_id.clone(),
                upstream: parse_upstream(&route.upstream)?,
            };
            if routes.insert(domain.clone(), validated).is_some() {
                return Err(format!("duplicate route domain {domain}"));
            }
        }

        Ok(ValidatedGatewayConfig {
            source: self,
            http_addr,
            https_addr,
            certificates,
            routes,
        })
    }
}

impl GatewaySecrets {
    pub fn parse(json: &str) -> Result<Self, String> {
        let secrets: Self = serde_json::from_str(json)
            .map_err(|error| format!("invalid gateway secrets JSON: {error}"))?;
        if secrets.schema_version != GATEWAY_SCHEMA_VERSION {
            return Err(format!(
                "unsupported gateway secrets schema_version {}; expected {GATEWAY_SCHEMA_VERSION}",
                secrets.schema_version
            ));
        }
        for (credential_id, secret) in &secrets.cloudflare {
            validate_identifier(credential_id, "credential id")?;
            if secret.api_token.trim().is_empty() {
                return Err(format!(
                    "Cloudflare credential {credential_id} has an empty api_token"
                ));
            }
        }
        Ok(secrets)
    }

    pub fn validate_references(&self, config: &ValidatedGatewayConfig) -> Result<(), String> {
        for certificate in config.certificates.values() {
            if let Some(credential_id) = certificate.challenge.credential_id()
                && !self.cloudflare.contains_key(credential_id)
            {
                return Err(format!(
                    "certificate {} references missing Cloudflare credential {credential_id}",
                    certificate.id
                ));
            }
        }
        Ok(())
    }
}

pub fn normalize_domain(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_end_matches('.');
    if trimmed.is_empty() {
        return Err("domain must not be empty".to_string());
    }
    if trimmed.contains('*') {
        return Err(format!("route domain must be exact, got {raw}"));
    }
    match Host::parse(trimmed).map_err(|error| format!("invalid domain {raw}: {error}"))? {
        Host::Domain(domain) => Ok(domain.to_ascii_lowercase()),
        Host::Ipv4(_) | Host::Ipv6(_) => Err(format!("domain must not be an IP address: {raw}")),
    }
}

pub fn normalize_certificate_domain(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_end_matches('.');
    if let Some(suffix) = trimmed.strip_prefix("*.") {
        if suffix.contains('*') {
            return Err(format!(
                "wildcard is only allowed in the leftmost label: {raw}"
            ));
        }
        return normalize_domain(suffix).map(|domain| format!("*.{domain}"));
    }
    normalize_domain(trimmed)
}

pub fn certificate_domain_covers(pattern: &str, domain: &str) -> bool {
    if pattern == domain {
        return true;
    }
    let Some(suffix) = pattern.strip_prefix("*.") else {
        return false;
    };
    let Some(prefix) = domain.strip_suffix(suffix) else {
        return false;
    };
    prefix.ends_with('.') && !prefix[..prefix.len() - 1].contains('.')
}

fn parse_listener(raw: &str, field: &str) -> Result<SocketAddr, String> {
    raw.parse()
        .map_err(|error| format!("{field} must be an IP socket address: {error}"))
}

fn parse_upstream(config: &UpstreamConfig) -> Result<ParsedUpstream, String> {
    let url = Url::parse(&config.url)
        .map_err(|error| format!("invalid upstream URL {}: {error}", config.url))?;
    let scheme = match url.scheme() {
        "http" => UpstreamScheme::Http,
        "https" => UpstreamScheme::Https,
        other => return Err(format!("unsupported upstream scheme {other}")),
    };
    if !url.username().is_empty() || url.password().is_some() {
        return Err("upstream URL must not include credentials".to_string());
    }
    if !(url.path().is_empty() || url.path() == "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("upstream URL must not include path, query, or fragment".to_string());
    }

    let host = url
        .host()
        .ok_or_else(|| "upstream URL must include a host".to_string())?;
    let (host, is_ip) = match host {
        Host::Domain(domain) => (normalize_domain(domain)?, false),
        Host::Ipv4(ip) => (ip.to_string(), true),
        Host::Ipv6(ip) => (ip.to_string(), true),
    };
    let port = url
        .port_or_known_default()
        .ok_or_else(|| "upstream URL must include a port".to_string())?;

    let host_header = config
        .host_header
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            HeaderValue::from_str(value)
                .map(|_| value.to_string())
                .map_err(|error| format!("invalid upstream host_header: {error}"))
        })
        .transpose()?;

    let tls_server_name = match scheme {
        UpstreamScheme::Http => {
            if config.tls_server_name.is_some() {
                return Err("tls_server_name is only valid for HTTPS upstreams".to_string());
            }
            None
        }
        UpstreamScheme::Https => match config.tls_server_name.as_deref() {
            Some(value) => Some(normalize_domain(value)?),
            None if is_ip => {
                return Err("HTTPS upstreams addressed by IP require tls_server_name".to_string());
            }
            None => Some(host.clone()),
        },
    };

    Ok(ParsedUpstream {
        original_url: config.url.clone(),
        scheme,
        host,
        port,
        host_header,
        tls_server_name,
    })
}

fn validate_acme_directory(directory: &AcmeDirectoryConfig) -> Result<(), String> {
    let AcmeDirectoryConfig::Custom { url, ca_cert_path } = directory else {
        return Ok(());
    };
    let parsed = Url::parse(url).map_err(|error| format!("invalid ACME directory URL: {error}"))?;
    if parsed.scheme() != "https" {
        return Err("custom ACME directory URL must use HTTPS".to_string());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() || parsed.fragment().is_some() {
        return Err(
            "custom ACME directory URL must not include credentials or fragment".to_string(),
        );
    }
    if !ca_cert_path.is_absolute() {
        return Err("custom ACME ca_cert_path must be absolute".to_string());
    }
    Ok(())
}

fn validate_identifier(value: &str, label: &str) -> Result<(), String> {
    if value.is_empty() || value.len() > 64 {
        return Err(format!("{label} must contain 1 to 64 characters"));
    }
    if matches!(value, "." | "..") {
        return Err(format!("{label} must not be a relative path component"));
    }
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return Err(format!(
            "{label} may contain only ASCII letters, numbers, '.', '-', and '_'"
        ));
    }
    Ok(())
}

fn validate_email(email: &str) -> Result<(), String> {
    let email = email.trim();
    if email.is_empty()
        || email.chars().any(char::is_whitespace)
        || !email.contains('@')
        || email.starts_with('@')
        || email.ends_with('@')
    {
        return Err("acme.contact_email is not a valid email address".to_string());
    }
    Ok(())
}

pub fn socket_host_port(host: &str, port: u16) -> String {
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V6(_)) => format!("[{host}]:{port}"),
        _ => format!("{host}:{port}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_config() -> GatewayConfig {
        GatewayConfig {
            schema_version: GATEWAY_SCHEMA_VERSION,
            storage_dir: PathBuf::from("/tmp/easytier-gateway-test"),
            listeners: ListenerConfig {
                http: "127.0.0.1:5002".to_string(),
                https: "127.0.0.1:8443".to_string(),
            },
            acme: AcmeConfig {
                directory: AcmeDirectoryConfig::LetsencryptStaging,
                contact_email: Some("ops@example.com".to_string()),
                terms_of_service_agreed: true,
            },
            certificates: vec![CertificateConfig {
                id: "app-cert".to_string(),
                domains: vec!["app.example.com".to_string()],
                challenge: ChallengeConfig::Http01,
            }],
            routes: vec![RouteConfig {
                domain: "app.example.com".to_string(),
                certificate_id: "app-cert".to_string(),
                upstream: UpstreamConfig {
                    url: "http://127.0.0.1:8080".to_string(),
                    host_header: None,
                    tls_server_name: None,
                },
            }],
        }
    }

    #[test]
    fn validates_exact_route_and_certificate() {
        let validated = base_config().validate().unwrap();
        assert!(validated.routes.contains_key("app.example.com"));
    }

    #[test]
    fn certificate_domains_are_normalized_as_a_stable_set() {
        let mut config = base_config();
        config.certificates[0].domains =
            vec!["B.Example.com.".to_string(), "a.example.com".to_string()];
        config.routes.clear();
        let validated = config.validate().unwrap();
        assert_eq!(
            validated.certificates["app-cert"].domains,
            ["a.example.com", "b.example.com"]
        );
    }

    #[test]
    fn wildcard_certificate_covers_one_label_only() {
        assert!(certificate_domain_covers(
            "*.example.com",
            "app.example.com"
        ));
        assert!(!certificate_domain_covers(
            "*.example.com",
            "deep.app.example.com"
        ));
        assert!(!certificate_domain_covers("*.example.com", "example.com"));
    }

    #[test]
    fn rejects_wildcard_http01_certificate() {
        let mut config = base_config();
        config.certificates[0].domains = vec!["*.example.com".to_string()];
        assert!(config.validate().unwrap_err().contains("wildcard"));
    }

    #[test]
    fn rejects_route_not_covered_by_certificate() {
        let mut config = base_config();
        config.routes[0].domain = "other.example.com".to_string();
        assert!(config.validate().unwrap_err().contains("does not cover"));
    }

    #[test]
    fn https_ip_upstream_requires_sni() {
        let mut config = base_config();
        config.routes[0].upstream.url = "https://127.0.0.1:8444".to_string();
        assert!(
            config
                .validate()
                .unwrap_err()
                .contains("require tls_server_name")
        );
    }

    #[test]
    fn rejects_certificate_id_that_is_a_relative_path_component() {
        for certificate_id in [".", ".."] {
            let mut config = base_config();
            config.certificates[0].id = certificate_id.to_string();
            config.routes[0].certificate_id = certificate_id.to_string();
            assert!(
                config
                    .validate()
                    .unwrap_err()
                    .contains("relative path component")
            );
        }
    }
}
