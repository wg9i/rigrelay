import SwiftUI
import BridgeCore

struct DashboardView: View {
    @EnvironmentObject var engine: BridgeEngine
    @EnvironmentObject var config: BridgeConfig

    var body: some View {
        VStack(spacing: 24) {

            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Rig Relay")
                        .font(.title2).bold()
                    Text("DXLab Commander ↔ flrig protocol adapter")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Connection status grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 16) {
                StatusCard(
                    title: "Commander",
                    subtitle: "\(config.commanderHost):\(config.commanderPort)",
                    state: engine.commanderState,
                    icon: "network"
                )
                StatusCard(
                    title: "N1MM / RUMLogNG",
                    subtitle: "\(config.n1mmHost):\(config.n1mmPort)",
                    state: engine.n1mmState,
                    icon: "dot.radiowaves.right",
                    connectedLabel: "Listening"
                )
                StatusCard(
                    title: "flrig Server",
                    subtitle: "\(config.flrigHost):\(config.flrigPort)",
                    state: engine.serverState,
                    icon: "server.rack",
                    clientCount: engine.xmlRpcClientCount
                )
            }

            // Radio info readout
            if engine.isRunning {
                RadioReadoutView(info: engine.lastRadioInfo, transmitting: engine.pttTransmitting, engine: engine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()

            // Start / Stop button
            Button(action: toggleBridge) {
                Label(engine.isRunning ? "Stop Bridge" : "Start Bridge",
                      systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)
            .controlSize(.large)
        }
        .padding()
        .animation(.easeInOut, value: engine.isRunning)
    }

    private func toggleBridge() {
        Task {
            if engine.isRunning {
                await engine.stop()
            } else {
                await engine.start()
            }
        }
    }
}

// MARK: - Status card

struct StatusCard: View {
    let title: String
    let subtitle: String
    let state: ConnectionState
    let icon: String
    var connectedLabel: String? = nil
    var clientCount: Int? = nil

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(stateColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: stateColor.opacity(0.5), radius: stateGlow ? 4 : 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(stateColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        }
    }

    private var stateColor: Color {
        if let count = clientCount, case .connected = state {
            return count > 0 ? .green : .orange
        }
        switch state {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return .gray
        case .failed:       return .red
        }
    }

    private var stateGlow: Bool {
        if case .connected = state { return true }
        return false
    }

    private var statusLabel: String {
        guard case .connected = state else { return state.label }
        if let count = clientCount { return count > 0 ? "Connected (\(count))" : "Listening" }
        return connectedLabel ?? state.label
    }
}

// MARK: - Radio readout

struct RadioReadoutView: View {
    let info: RadioInfo
    let transmitting: Bool
    let engine: BridgeEngine

    private var splitOn: Bool {
        let rx = effectiveRxFreq
        let tx = effectiveTxFreq
        if rx != nil && tx != nil { return rx != tx }
        return false
    }

    // Use N1MM data if available
    private var effectiveRxFreq: Int64? {
        info.freqHz
    }

    private var effectiveTxFreq: Int64? {
        info.txFreqHz
    }

    private var effectiveMode: String {
        if !info.mode.isEmpty {
            return info.mode
        }
        return "—"
    }

    var body: some View {
        GroupBox("Radio Status") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    readoutLabel("VFO A (RX)")
                    Text(formattedFreq(effectiveRxFreq))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    readoutLabel("VFO B (TX)")
                    Text(formattedFreq(effectiveTxFreq))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    readoutLabel("Split")
                    HStack(spacing: 6) {
                        Circle()
                            .fill(splitOn ? Color.orange : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(splitOn ? "ON" : "OFF")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(splitOn ? Color.orange : Color.secondary)
                    }
                }
                GridRow {
                    readoutLabel("Mode")
                    Text(effectiveMode)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    readoutLabel("PTT")
                    HStack(spacing: 6) {
                        Circle()
                            .fill(transmitting ? Color.red : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(transmitting ? "TX" : "RX")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(transmitting ? Color.red : Color.primary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func readoutLabel(_ s: String) -> some View {
        Text(s)
            .foregroundStyle(.secondary)
            .frame(width: 80, alignment: .trailing)
    }

    private func formattedFreq(_ hz: Int64?) -> String {
        guard let hz else { return "—" }
        let mhz = Double(hz) / 1_000_000.0
        return String(format: "%.4f MHz", mhz)
    }
}

// MARK: - Menu bar view

struct MenuBarView: View {
    @EnvironmentObject var engine: BridgeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RigRelay")
                .font(.headline)
                .padding(.bottom, 4)

            HStack {
                Circle().fill(engine.isRunning ? Color.green : .gray).frame(width: 8, height: 8)
                Text(engine.isRunning ? "Running" : "Stopped")
                    .font(.subheadline)
            }

            if engine.isRunning {
                Text(formattedFreq(engine.lastRadioInfo.freqHz))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(engine.isRunning ? "Stop Bridge" : "Start Bridge") {
                Task {
                    if engine.isRunning { await engine.stop() }
                    else { await engine.start() }
                }
            }
        }
        .padding()
        .frame(minWidth: 200)
    }

    private func formattedFreq(_ hz: Int64?) -> String {
        guard let hz else { return "No frequency" }
        return String(format: "%.4f MHz", Double(hz) / 1_000_000.0)
    }
}
