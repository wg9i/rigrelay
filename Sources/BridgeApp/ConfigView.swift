import SwiftUI
import BridgeCore

// IntegerFormatStyle with grouping disabled — no thousands commas in port fields.
private let portFormat = IntegerFormatStyle<Int>().grouping(.never)

struct ConfigView: View {
    // @ObservedObject (not @EnvironmentObject) gives us $config bindings that
    // SwiftUI can write back to on macOS without the grouped Form blocking edits.
    @ObservedObject var config: BridgeConfig
    @EnvironmentObject var engine: BridgeEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                SettingsSection(title: "Commander / RUMLogNG") {
                    LabeledRow(label: "Host") {
                        TextField("127.0.0.1", text: $config.commanderHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: "Port") {
                        TextField("50000", value: $config.commanderPort, format: portFormat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }

                SettingsSection(title: "N1MM / RUMLog UDP Listener") {
                    LabeledRow(label: "Bind address") {
                        TextField("0.0.0.0", text: $config.n1mmHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: "Port") {
                        TextField("12060", value: $config.n1mmPort, format: portFormat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    Text("Use 0.0.0.0 to listen on all interfaces, or a specific IP to restrict access. Supports multicast.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "flrig XML-RPC Server") {
                    LabeledRow(label: "Bind address") {
                        TextField("0.0.0.0", text: $config.flrigHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: "Port") {
                        TextField("12345", value: $config.flrigPort, format: portFormat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    LabeledRow(label: "Rig name") {
                        TextField("IC-7300", text: $config.rigName)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: "Power (W)") {
                        TextField("100", value: $config.flrigPower, format: portFormat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    Text("Use 0.0.0.0 to listen on all interfaces, or a specific IP to restrict access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Diagnostics") {
                    Toggle("Start bridge at launch", isOn: $config.startAtLaunch)
                    LabeledRow(label: "Log buffer") {
                        TextField("1000", value: $config.logBufferSize, format: portFormat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("entries")
                            .foregroundStyle(.secondary)
                    }
                }

                if engine.isRunning {
                    Label("Stop the bridge to apply connection changes.", systemImage: "info.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
    }
}

// MARK: - Layout helpers

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            content()
            Spacer()
        }
    }
}
