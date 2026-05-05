import SwiftUI
import BridgeCore

struct ModeMappingsView: View {
    @EnvironmentObject var config: BridgeConfig
    @State private var editingN1MM: (String, String)? = nil
    @State private var editingFlrig: (String, String)? = nil

    var body: some View {
        HSplitView {
            // N1MM → flrig table
            VStack(alignment: .leading, spacing: 8) {
                Text("N1MM / RUMLog → flrig")
                    .font(.headline)
                Text("How incoming modes are translated for flrig clients.")
                    .font(.caption).foregroundStyle(.secondary)

                MappingTable(
                    title: "N1MM mode",
                    valueTitle: "flrig mode",
                    mappings: $config.modeMappings
                )

                Button("Reset to defaults") {
                    config.modeMappings = BridgeConfig.defaultN1MMToFlrig
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .frame(minWidth: 280)

            // flrig → Commander table
            VStack(alignment: .leading, spacing: 8) {
                Text("flrig → Commander")
                    .font(.headline)
                Text("How set_mode calls are translated when sent to Commander.")
                    .font(.caption).foregroundStyle(.secondary)

                MappingTable(
                    title: "flrig mode",
                    valueTitle: "Commander mode",
                    mappings: $config.commanderModeMappings
                )

                Button("Reset to defaults") {
                    config.commanderModeMappings = BridgeConfig.defaultFlrigToCommander
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .frame(minWidth: 280)
        }
    }
}

/// Identifiable wrapper so Table can use plain strings as rows.
private struct MappingRow: Identifiable {
    let id: String   // the source mode key
    let value: String
}

struct MappingTable: View {
    let title: String
    let valueTitle: String
    @Binding var mappings: [String: String]

    @State private var newKey = ""
    @State private var newValue = ""

    private var rows: [MappingRow] {
        mappings.keys.sorted().map { MappingRow(id: $0, value: mappings[$0] ?? "") }
    }

    var body: some View {
        Table(rows) {
            TableColumn(title) { row in
                Text(row.id)
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn(valueTitle) { row in
                Text(row.value)
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("") { row in
                Button {
                    mappings.removeValue(forKey: row.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .width(24)
        }
        .frame(minHeight: 200)

        // Add new mapping row
        HStack {
            TextField("Source", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Target", text: $newValue)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Button {
                let k = newKey.trimmingCharacters(in: .whitespaces)
                let v = newValue.trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty, !v.isEmpty else { return }
                mappings[k] = v
                newKey = ""; newValue = ""
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
        }
        .padding(.top, 4)
    }
}
