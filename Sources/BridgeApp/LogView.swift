import SwiftUI
import BridgeCore
import AppKit

struct LogView: View {
    @EnvironmentObject var engine: BridgeEngine
    @EnvironmentObject var config: BridgeConfig
    @State private var autoScroll = true

    private func copyLogToClipboard() {
        let filteredEntries = engine.logEntries.filter { config.logFilter.matches($0.level) }
        let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
        let logText = filteredEntries.map { entry in
            let time = timeFormatter.string(from: entry.timestamp)
            let level = levelTag(for: entry.level)
            return "\(time) [\(level)] \(entry.message)"
        }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logText, forType: .string)
    }

    private func levelTag(for level: LogEntry.Level) -> String {
        switch level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Picker("Filter", selection: $config.logFilter) {
                    ForEach(LogFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button("Copy") { copyLogToClipboard() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Clear") { engine.clearLog() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(engine.logEntries) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: engine.logEntries.count) { _ in
                    if autoScroll, let last = engine.logEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(LogRow.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(levelTag)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(levelColor.opacity(0.15))
                .foregroundStyle(levelColor)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(width: 46)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var levelTag: String {
        switch entry.level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:   return .secondary
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }

    private var entryColor: Color {
        switch entry.level {
        case .error:   return .red
        case .warning: return .orange
        default:       return .primary
        }
    }
}
