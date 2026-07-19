import EasyTierShared
import SwiftUI

struct PublishedServicesList: View {
    let services: [GatewayPublishedService]
    let status: GatewayStatus
    let gatewayEnabled: Bool
    let tlsConfigured: Bool
    let gatewayBusy: Bool
    let workingServiceID: String?
    let onSetEnabled: (Bool, GatewayPublishedService) -> Void
    let onEditPort: (GatewayPublishedService) -> Void
    let onRetryCertificate: (GatewayPublishedService) -> Void
    let onOpen: (GatewayPublishedService) -> Void
    let onCopyHostname: (GatewayPublishedService) -> Void
    let onDelete: (GatewayPublishedService) -> Void

    var body: some View {
        ScrollView {
            SettingsCard {
                VStack(spacing: 0) {
                    ForEach(services) { service in
                        PublishedServiceRow(
                            service: service,
                            presentation: presentation(for: service),
                            isWorking: gatewayBusy || workingServiceID == service.id,
                            onSetEnabled: { enabled in
                                onSetEnabled(enabled, service)
                            },
                            onEditPort: {
                                onEditPort(service)
                            },
                            onRetryCertificate: {
                                onRetryCertificate(service)
                            },
                            onOpen: {
                                onOpen(service)
                            },
                            onCopyHostname: {
                                onCopyHostname(service)
                            },
                            onDelete: {
                                onDelete(service)
                            }
                        )

                        if service.id != services.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func presentation(for service: GatewayPublishedService) -> PublishedServicePresentation {
        PublishedServicePresentation(
            service: service,
            certificate: status.certificates.first { $0.id == service.id },
            route: status.routes.first { $0.domain == service.publicHostname },
            gatewayEnabled: gatewayEnabled,
            tlsConfigured: tlsConfigured
        )
    }
}
