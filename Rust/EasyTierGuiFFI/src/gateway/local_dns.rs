use std::{collections::BTreeSet, net::SocketAddr, sync::Arc};

use arc_swap::ArcSwap;
use hickory_resolver::proto::{
    op::{Message, MessageType, ResponseCode},
    rr::{RData, Record, RecordType, rdata::A},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    sync::watch,
    task::JoinHandle,
};

use super::{config::ValidatedGatewayConfig, tls::DynamicCertificateStore};

#[derive(Clone)]
pub struct LocalDnsTable {
    domains: BTreeSet<String>,
    answer: std::net::Ipv4Addr,
    ttl: u32,
}

impl LocalDnsTable {
    pub fn from_config(config: &ValidatedGatewayConfig) -> Arc<Self> {
        Arc::new(Self {
            domains: config.local_dns_domains.clone(),
            answer: config.source.local_dns.answer_ipv4,
            ttl: config.source.local_dns.ttl,
        })
    }
}

pub struct SharedLocalDnsTable {
    current: ArcSwap<LocalDnsTable>,
}

impl SharedLocalDnsTable {
    pub fn new(table: Arc<LocalDnsTable>) -> Arc<Self> {
        Arc::new(Self {
            current: ArcSwap::from(table),
        })
    }

    pub fn replace(&self, table: Arc<LocalDnsTable>) {
        self.current.store(table);
    }
}

pub async fn bind_local_dns(
    requested: SocketAddr,
) -> Result<(TcpListener, UdpSocket, SocketAddr), String> {
    let tcp = TcpListener::bind(requested)
        .await
        .map_err(|error| format!("failed to bind local DNS TCP listener {requested}: {error}"))?;
    let address = tcp
        .local_addr()
        .map_err(|error| format!("failed to inspect local DNS listener: {error}"))?;
    let udp = UdpSocket::bind(address)
        .await
        .map_err(|error| format!("failed to bind local DNS UDP listener {address}: {error}"))?;
    Ok((tcp, udp, address))
}

pub fn spawn_local_dns(
    tcp: TcpListener,
    udp: UdpSocket,
    table: Arc<SharedLocalDnsTable>,
    certificates: Arc<DynamicCertificateStore>,
    shutdown: watch::Receiver<bool>,
) -> Vec<JoinHandle<()>> {
    vec![
        tokio::spawn(run_udp(
            udp,
            table.clone(),
            certificates.clone(),
            shutdown.clone(),
        )),
        tokio::spawn(run_tcp(tcp, table, certificates, shutdown)),
    ]
}

async fn run_udp(
    socket: UdpSocket,
    table: Arc<SharedLocalDnsTable>,
    certificates: Arc<DynamicCertificateStore>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut buffer = [0_u8; 4096];
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return; }
            }
            received = socket.recv_from(&mut buffer) => {
                let Ok((length, peer)) = received else { continue };
                let Some(response) = response_bytes(
                    &buffer[..length],
                    &table.current.load(),
                    &certificates,
                ) else { continue };
                let _ = socket.send_to(&response, peer).await;
            }
        }
    }
}

async fn run_tcp(
    listener: TcpListener,
    table: Arc<SharedLocalDnsTable>,
    certificates: Arc<DynamicCertificateStore>,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return; }
            }
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else { continue };
                let table = table.clone();
                let certificates = certificates.clone();
                tokio::spawn(async move {
                    let _ = serve_tcp_query(stream, table, certificates).await;
                });
            }
        }
    }
}

async fn serve_tcp_query(
    mut stream: TcpStream,
    table: Arc<SharedLocalDnsTable>,
    certificates: Arc<DynamicCertificateStore>,
) -> Result<(), String> {
    let length = stream
        .read_u16()
        .await
        .map_err(|error| format!("failed to read DNS TCP length: {error}"))?
        as usize;
    if length == 0 || length > 4096 {
        return Err("invalid DNS TCP message length".to_string());
    }
    let mut request = vec![0_u8; length];
    stream
        .read_exact(&mut request)
        .await
        .map_err(|error| format!("failed to read DNS TCP request: {error}"))?;
    let response = response_bytes(&request, &table.current.load(), &certificates)
        .ok_or_else(|| "failed to encode DNS response".to_string())?;
    stream
        .write_u16(response.len() as u16)
        .await
        .map_err(|error| format!("failed to write DNS TCP length: {error}"))?;
    stream
        .write_all(&response)
        .await
        .map_err(|error| format!("failed to write DNS TCP response: {error}"))
}

fn response_bytes(
    request_bytes: &[u8],
    table: &LocalDnsTable,
    certificates: &DynamicCertificateStore,
) -> Option<Vec<u8>> {
    let request = Message::from_vec(request_bytes).ok()?;
    let mut response = Message::new();
    response
        .set_id(request.id())
        .set_message_type(MessageType::Response)
        .set_op_code(request.op_code())
        .set_authoritative(true)
        .set_recursion_desired(request.recursion_desired())
        .set_recursion_available(false);
    response.add_queries(request.queries().to_vec());

    let Some(query) = request.queries().first() else {
        response.set_response_code(ResponseCode::FormErr);
        return response.to_vec().ok();
    };
    let domain = query
        .name()
        .to_ascii()
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if !table.domains.contains(&domain) {
        response.set_response_code(ResponseCode::NXDomain);
        return response.to_vec().ok();
    }
    if !certificates.has_certificate_for_domain(&domain) {
        response.set_response_code(ResponseCode::ServFail);
        return response.to_vec().ok();
    }
    if query.query_type() == RecordType::A {
        response.add_answer(Record::from_rdata(
            query.name().clone(),
            table.ttl,
            RData::A(A(table.answer)),
        ));
    }
    response.to_vec().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hickory_resolver::proto::{op::Query, rr::Name};
    use rcgen::{CertificateParams, KeyPair};
    use std::str::FromStr;
    use time::OffsetDateTime;
    use tokio::net::{TcpStream, UdpSocket};

    use crate::gateway::config::GatewayConfig;
    use crate::gateway::tls::CertifiedMaterial;

    #[test]
    fn unknown_domain_returns_nxdomain_without_certificate_material() {
        let table = LocalDnsTable {
            domains: BTreeSet::from(["app.example.com".to_string()]),
            answer: std::net::Ipv4Addr::LOCALHOST,
            ttl: 30,
        };
        let certificates = DynamicCertificateStore::new();
        let mut request = Message::new();
        request.set_id(7).add_query(Query::query(
            Name::from_str("unknown.example.com.").unwrap(),
            RecordType::A,
        ));
        let response = Message::from_vec(
            &response_bytes(&request.to_vec().unwrap(), &table, &certificates).unwrap(),
        )
        .unwrap();
        assert_eq!(response.response_code(), ResponseCode::NXDomain);
    }

    #[test]
    fn configured_domain_returns_servfail_until_certificate_is_ready() {
        let table = LocalDnsTable {
            domains: BTreeSet::from(["app.example.com".to_string()]),
            answer: std::net::Ipv4Addr::LOCALHOST,
            ttl: 30,
        };
        let certificates = DynamicCertificateStore::new();
        let request = dns_request("app.example.com.", RecordType::A);
        let response = Message::from_vec(
            &response_bytes(&request.to_vec().unwrap(), &table, &certificates).unwrap(),
        )
        .unwrap();

        assert_eq!(response.response_code(), ResponseCode::ServFail);
    }

    #[tokio::test]
    async fn udp_and_tcp_return_the_exact_loopback_a_record() {
        let domain = "app.example.com";
        let table = SharedLocalDnsTable::new(Arc::new(LocalDnsTable {
            domains: BTreeSet::from([domain.to_string()]),
            answer: std::net::Ipv4Addr::LOCALHOST,
            ttl: 30,
        }));
        let certificates = DynamicCertificateStore::new();
        certificates.update_routes(&test_config(domain));
        certificates.install("app-cert".to_string(), test_material(domain));
        let (tcp, udp, address) = bind_local_dns("127.0.0.1:0".parse().unwrap())
            .await
            .unwrap();
        let (shutdown, receiver) = watch::channel(false);
        let tasks = spawn_local_dns(tcp, udp, table, certificates, receiver);
        let request = dns_request("app.example.com.", RecordType::A)
            .to_vec()
            .unwrap();

        let udp_client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        udp_client.send_to(&request, address).await.unwrap();
        let mut udp_buffer = [0_u8; 2048];
        let (udp_length, _) = udp_client.recv_from(&mut udp_buffer).await.unwrap();
        assert_loopback_answer(&udp_buffer[..udp_length]);

        let mut tcp_client = TcpStream::connect(address).await.unwrap();
        tcp_client.write_u16(request.len() as u16).await.unwrap();
        tcp_client.write_all(&request).await.unwrap();
        let tcp_length = tcp_client.read_u16().await.unwrap() as usize;
        let mut tcp_response = vec![0_u8; tcp_length];
        tcp_client.read_exact(&mut tcp_response).await.unwrap();
        assert_loopback_answer(&tcp_response);

        let _ = shutdown.send(true);
        for task in tasks {
            task.await.unwrap();
        }
    }

    fn dns_request(domain: &str, record_type: RecordType) -> Message {
        let mut request = Message::new();
        request
            .set_id(7)
            .add_query(Query::query(Name::from_str(domain).unwrap(), record_type));
        request
    }

    fn assert_loopback_answer(bytes: &[u8]) {
        let response = Message::from_vec(bytes).unwrap();
        assert_eq!(response.response_code(), ResponseCode::NoError);
        assert_eq!(response.answers().len(), 1);
        assert_eq!(
            response.answers()[0].data(),
            &RData::A(A(std::net::Ipv4Addr::LOCALHOST))
        );
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

    fn test_config(domain: &str) -> super::ValidatedGatewayConfig {
        GatewayConfig::parse(
            &serde_json::json!({
                "schema_version": 2,
                "storage_dir": "/tmp/easytier-local-dns-test",
                "listeners": {
                    "http": "127.0.0.1:0",
                    "https": "127.0.0.1:0",
                    "dns": "127.0.0.1:0"
                },
                "local_dns": {
                    "domains": [domain],
                    "answer_ipv4": "127.0.0.1",
                    "ttl": 30
                },
                "acme": {
                    "directory": { "kind": "letsencrypt_staging" },
                    "contact_email": null,
                    "terms_of_service_agreed": true
                },
                "certificates": [{
                    "id": "app-cert",
                    "domains": [domain],
                    "challenge": { "type": "http01" }
                }],
                "routes": [{
                    "domain": domain,
                    "certificate_id": "app-cert",
                    "upstream": {
                        "url": "http://127.0.0.1:3000",
                        "host_header": null,
                        "tls_server_name": null,
                        "allowed_ipv4_cidr": null
                    }
                }]
            })
            .to_string(),
        )
        .unwrap()
        .validate()
        .unwrap()
    }
}
