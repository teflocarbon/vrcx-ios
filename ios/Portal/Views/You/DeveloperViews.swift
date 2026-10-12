import SwiftUI

/// The last requests Portal made, without headers or query strings, for
/// working out what went wrong
struct NetworkLogView: View {
    @State private var entries = NetworkLog.shared.snapshot

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Requests Yet", systemImage: "network", description: Text("Requests to VRChat or your relay show here."))
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.method).font(.caption.monospaced().weight(.semibold))
                        Text(entry.status.map(String.init) ?? "failed")
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.status.map { (200..<300).contains($0) } ?? false ? Palette.online : Palette.busy)
                        Spacer()
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.url.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption.monospaced())
                        .lineLimit(2)
                    if let detail = entry.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .navigationTitle("Network Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = NetworkLog.shared.transcript
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        NetworkLog.shared.clear()
                        entries = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .refreshable { entries = NetworkLog.shared.snapshot }
    }
}

/// The last pipeline events, by type and time only: their content holds
/// other people's details, so it stays on the phone and out of copies
struct EventLogView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let events = session.recentEvents
            List {
                Section {
                    if events.isEmpty {
                        Text("No events yet. They arrive while Portal is open and connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                        HStack {
                            Text(event.type).font(.callout.monospaced())
                            Spacer()
                            Text(event.received.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("The last 100 events from the live connection, newest first.")
                }
            }
        }
        .navigationTitle("Live Events")
        .navigationBarTitleDisplayMode(.inline)
    }
}
