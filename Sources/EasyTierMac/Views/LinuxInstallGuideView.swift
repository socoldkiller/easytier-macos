import AppKit
import SwiftUI

struct LinuxInstallGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HeaderRow()
                }

                Section("Install") {
                    StepRow(
                        number: 1,
                        title: "Connect to the Linux machine",
                        detail: "Open a terminal on your VPS, NAS, or server.",
                        command: "ssh user@linux-host"
                    )

                    StepRow(
                        number: 2,
                        title: "Install EasyTier Core",
                        detail: "The script installs to /opt/easytier and starts easytier@default.",
                        command: "curl -fsSL \"https://github.com/EasyTier/EasyTier/blob/main/script/install.sh?raw=true\" | sudo bash -s install"
                    )

                    StepRow(
                        number: 3,
                        title: "Copy this network config",
                        detail: "In this Mac app, choose TOML > Export TOML, then replace the default Linux config.",
                        command: "sudo nano /opt/easytier/config/default.conf\nsudo systemctl restart easytier@default",
                        footnote: "OpenRC: sudo rc-service easytier restart"
                    )

                    StepRow(
                        number: 4,
                        title: "Check the Linux node",
                        detail: "Confirm the service is running and peers are visible.",
                        command: "systemctl status easytier@default\neasytier-cli peer"
                    )
                }

                Section("Troubleshooting") {
                    NoteRow("Missing curl or unzip: install them with your system package manager.")
                    NoteRow("Linux node does not appear: check that network_name and network_secret match this Mac.")
                    NoteRow("Connection fails: allow TCP/UDP 11010, or open the ports listed in listeners.")
                    NoteRow("Do not want to run the script: download a prebuilt package from Releases.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .hideScrollViewScrollers()
            .padding(.top, 10)
            .padding(.horizontal, 10)

            Divider()

            HStack(spacing: 14) {
                Link("Documentation", destination: URL(string: "https://easytier.cn/guide/installation.html") ?? URL(fileURLWithPath: "/"))
                    .accessibilityHint("Opens the EasyTier installation guide in your browser.")
                Link("Releases", destination: URL(string: "https://github.com/EasyTier/EasyTier/releases") ?? URL(fileURLWithPath: "/"))
                    .accessibilityHint("Opens the EasyTier Core releases page in your browser.")
                Link("Service guide", destination: URL(string: "https://easytier.cn/guide/network/oneclick-install-as-service.html") ?? URL(fileURLWithPath: "/"))
                    .accessibilityHint("Opens the EasyTier service install guide in your browser.")

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes the Linux install guide.")
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 520)
        .presentationBackground { FrostedGlass() }
        .hideScrollViewScrollers()
    }
}

private struct HeaderRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("Install EasyTier on Linux")
                    .font(.headline)
                Text("Add a VPS, NAS, or server to the current EasyTier network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StepRow: View {
    var number: Int
    var title: String
    var detail: String
    var command: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(number). \(title). \(detail)")

            CommandField(command: command)
                .padding(.leading, 30)
                .accessibilityLabel("Step \(number) command")
                .accessibilityValue(command)

            if let footnote {
                Text(footnote)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct CommandField: View {
    var command: String

    @State private var copied = false
    @State private var copyToken = 0

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .fixedSize(horizontal: true, vertical: false)
                    .hideEnclosingScrollViewScrollers()
            }
            .scrollIndicators(.hidden)

            Button {
                copy(command)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy command")
            .padding(.trailing, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        copyToken += 1
        let token = copyToken
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                if copyToken == token { copied = false }
            }
        }
    }
}

private struct NoteRow: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .frame(width: 10)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#Preview {
    LinuxInstallGuideView()
}
