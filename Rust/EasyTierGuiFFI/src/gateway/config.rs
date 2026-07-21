use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::PathBuf,
};

use http::HeaderValue;
use serde::{Deserialize, Serialize};
use url::{Host, Url};

pub const GATEWAY_SCHEMA_VERSION: u32 = 4;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GatewayConfig {
    pub schema_version: u32,
    pub storage_dir: PathBuf,
    pub listeners: ListenerConfig,
    pub local_dns: LocalDnsConfig,
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
    pub dns: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LocalDnsConfig {
    #[serde(default)]
    pub domains: Vec<String>,
    pub answer_ipv4: Ipv4Addr,
    pub ttl: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AcmeConfig {
    #[serde(default)]
    pub directory: AcmeDirectoryConfig,
    pub contact_email: Option<String>,
    pub terms_of_service_agreed: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AcmeDirectoryConfig {
    #[default]
    LetsencryptStaging,
    LetsencryptProduction,
    Custom {
        url: String,
        ca_cert_path: PathBuf,
    },
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

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ChallengeConfig {
    Automatic {
        #[serde(default)]
        dns01: Option<Dns01Config>,
    },
    Http01,
    Dns01 {
        provider: DnsProviderKind,
        credential_id: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Dns01Config {
    pub provider: DnsProviderKind,
    pub credential_id: String,
}

impl ChallengeConfig {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Automatic { .. } => "automatic",
            Self::Http01 => "http01",
            Self::Dns01 { .. } => "dns01",
        }
    }

    pub fn dns01(&self) -> Option<(DnsProviderKind, &str)> {
        match self {
            Self::Automatic { dns01: Some(dns01) } => {
                Some((dns01.provider, dns01.credential_id.as_str()))
            }
            Self::Dns01 {
                provider,
                credential_id,
            } => Some((*provider, credential_id.as_str())),
            Self::Automatic { dns01: None } | Self::Http01 => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DnsProviderKind {
    Cloudflare,
    Aliyun,
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
    pub allowed_ipv4_cidr: Option<String>,
    pub availability: UpstreamAvailability,
    pub expected_ipv4: Option<Ipv4Addr>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum UpstreamAvailability {
    Waiting,
    Unavailable,
    #[default]
    Ready,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GatewaySecrets {
    pub schema_version: u32,
    #[serde(default)]
    pub cloudflare: BTreeMap<String, CloudflareSecret>,
    #[serde(default)]
    pub aliyun: BTreeMap<String, AliyunSecret>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloudflareSecret {
    pub api_token: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AliyunSecret {
    pub access_key_id: String,
    pub access_key_secret: String,
}

#[derive(Clone, Debug)]
pub struct ValidatedGatewayConfig {
    pub source: GatewayConfig,
    pub http_addr: SocketAddr,
    pub https_addr: SocketAddr,
    pub dns_addr: SocketAddr,
    pub local_dns_domains: BTreeSet<String>,
    pub certificates: BTreeMap<String, ValidatedCertificate>,
    pub routes: BTreeMap<String, ValidatedRoute>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
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
    pub allowed_ipv4_cidr: Option<Ipv4Cidr>,
    pub availability: UpstreamAvailability,
    pub expected_ipv4: Option<Ipv4Addr>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ipv4Cidr {
    network: u32,
    prefix: u8,
}

impl Ipv4Cidr {
    pub fn contains(self, address: Ipv4Addr) -> bool {
        let mask = if self.prefix == 0 {
            0
        } else {
            u32::MAX << (32 - self.prefix)
        };
        u32::from(address) & mask == self.network
    }
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
        if !self.certificates.is_empty() {
            if !self.acme.terms_of_service_agreed {
                return Err("acme.terms_of_service_agreed must be true".to_string());
            }
            if self.acme.contact_email.is_none() {
                return Err(
                    "acme.contact_email is required when certificates are enabled".to_string(),
                );
            }
        }
        if let Some(email) = self.acme.contact_email.as_deref() {
            validate_email(email)?;
        }
        validate_acme_directory(&self.acme.directory)?;

        let http_addr = parse_listener(&self.listeners.http, "listeners.http")?;
        let https_addr = parse_listener(&self.listeners.https, "listeners.https")?;
        let dns_addr = parse_listener(&self.listeners.dns, "listeners.dns")?;
        if http_addr == https_addr && http_addr.port() != 0 {
            return Err("HTTP and HTTPS listeners must use different addresses".to_string());
        }
        if !https_addr.ip().is_loopback() {
            return Err("listeners.https must bind a loopback address".to_string());
        }
        if !dns_addr.ip().is_loopback() {
            return Err("listeners.dns must bind a loopback address".to_string());
        }
        if !(1..=300).contains(&self.local_dns.ttl) {
            return Err("local_dns.ttl must be between 1 and 300 seconds".to_string());
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
                ChallengeConfig::Automatic { dns01 } => {
                    if domains.iter().any(|domain| domain.starts_with("*.")) && dns01.is_none() {
                        return Err(format!(
                            "certificate {} uses Automatic for a wildcard but has no DNS credential",
                            certificate.id
                        ));
                    }
                    if let Some(dns01) = dns01 {
                        validate_identifier(&dns01.credential_id, "credential id")?;
                    }
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

        let mut local_dns_domains = BTreeSet::new();
        for domain in &self.local_dns.domains {
            let domain = normalize_domain(domain)?;
            if !routes.contains_key(&domain) {
                return Err(format!("local DNS domain {domain} does not have a route"));
            }
            if !local_dns_domains.insert(domain.clone()) {
                return Err(format!("duplicate local DNS domain {domain}"));
            }
        }

        Ok(ValidatedGatewayConfig {
            source: self,
            http_addr,
            https_addr,
            dns_addr,
            local_dns_domains,
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
        for (credential_id, secret) in &secrets.aliyun {
            validate_identifier(credential_id, "credential id")?;
            if secret.access_key_id.trim().is_empty() || secret.access_key_secret.trim().is_empty()
            {
                return Err(format!(
                    "Aliyun credential {credential_id} has an empty access key field"
                ));
            }
        }
        Ok(secrets)
    }

    pub fn validate_references(&self, config: &ValidatedGatewayConfig) -> Result<(), String> {
        // Keychain items can be unavailable at launch. ACME treats a missing DNS
        // credential as an attempt failure and keeps the Gateway in HTTP-only mode.
        let _ = config;
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
    let allowed_ipv4_cidr = config
        .allowed_ipv4_cidr
        .as_deref()
        .map(parse_ipv4_cidr)
        .transpose()?;
    match config.availability {
        UpstreamAvailability::Waiting | UpstreamAvailability::Unavailable
            if config.expected_ipv4.is_some() =>
        {
            return Err("a non-ready upstream must not include expected_ipv4".to_string());
        }
        _ => {}
    }
    if let (Some(cidr), Some(expected)) = (allowed_ipv4_cidr, config.expected_ipv4)
        && !cidr.contains(expected)
    {
        return Err("expected_ipv4 must be inside allowed_ipv4_cidr".to_string());
    }

    Ok(ParsedUpstream {
        original_url: config.url.clone(),
        scheme,
        host,
        port,
        host_header,
        tls_server_name,
        allowed_ipv4_cidr,
        availability: config.availability,
        expected_ipv4: config.expected_ipv4,
    })
}

fn parse_ipv4_cidr(raw: &str) -> Result<Ipv4Cidr, String> {
    let (address, prefix) = raw
        .trim()
        .split_once('/')
        .ok_or_else(|| format!("invalid allowed_ipv4_cidr {raw}"))?;
    let address = address
        .parse::<Ipv4Addr>()
        .map_err(|error| format!("invalid allowed_ipv4_cidr {raw}: {error}"))?;
    let prefix = prefix
        .parse::<u8>()
        .map_err(|error| format!("invalid allowed_ipv4_cidr {raw}: {error}"))?;
    if prefix > 32 {
        return Err(format!(
            "invalid allowed_ipv4_cidr {raw}: prefix exceeds 32"
        ));
    }
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    Ok(Ipv4Cidr {
        network: u32::from(address) & mask,
        prefix,
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
                dns: "127.0.0.1:53535".to_string(),
            },
            local_dns: LocalDnsConfig {
                domains: vec!["app.example.com".to_string()],
                answer_ipv4: Ipv4Addr::LOCALHOST,
                ttl: 30,
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
                    allowed_ipv4_cidr: None,
                    availability: UpstreamAvailability::Ready,
                    expected_ipv4: None,
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
        config.local_dns.domains.clear();
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
