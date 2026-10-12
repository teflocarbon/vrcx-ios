import SwiftUI

/// The connection's details: the relay's health and what it offers, or
/// VRChat; and signing out
struct ConnectionView: View {
    @Environment(SessionStore.self) private var session
    @State private var health: RelayHealth?
    @State private var capabilities: RelayCapabilities?
    @State private var checking = false
    @State private var confirmSignOut = false

    var body: some View {
        List {
            if case .relay(let origin)? = session.connection {
                Section {
                    LabeledContent("Address", value: origin.host() ?? origin.absoluteString)
                    if let health {
                        LabeledContent("Relay Version", value: health.version)
                        LabeledContent("VRChat") {
                            Text(health.vrchat == "signedIn" ? "Signed In" : health.vrchat == "signedOut" ? "Signed Out" : "Starting")
                                .foregroundStyle(health.vrchat == "signedIn" ? Palette.online : Palette.busy)
                        }
                        LabeledContent("Live Connection", value: health.pipeline ? "Open" : "Closed")
                    } else if checking {
                        HStack {
                            ProgressView()
                            Text("Checking the relay…").foregroundStyle(.secondary)
                        }
                    }
                    if let capabilities {
                        LabeledContent("History", value: capabilities.features.events
                            ? (capabilities.events?.retentionDays.map { "\($0) days" } ?? "On") : "Off")
                        LabeledContent("Push Notifications", value: capabilities.features.push ? "Available" : "Not Set Up")
                    }
                    Link(destination: origin.appending(path: "admin")) {
                        Label("Open Admin Page", systemImage: "safari")
                    }
                } header: {
                    Text("Relay")
                } footer: {
                    Text("Your relay holds your VRChat session, so your password never reaches this phone. If it's signed out of VRChat, sign it in again from its admin page.")
                }
            } else {
                Section {
                    LabeledContent("Connected To", value: "VRChat")
                    if let name = session.me?.displayName {
                        LabeledContent("Signed In As", value: name)
                    }
                } footer: {
                    Text("Portal talks to VRChat directly. Push notifications and history from while Portal was closed need a VRCX relay.")
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmSignOut = true
                }
            } footer: {
                Text(session.connection?.isRelay == true
                    ? "Signs this phone out of your relay. The relay stays signed in to VRChat."
                    : "Ends this VRChat session. VRCX and the game stay signed in.")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of Portal?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await session.signOut() }
            }
        }
        .task { await check() }
        .refreshable { await check() }
    }

    private func check() async {
        guard !Demo.isOn, case .relay(let origin)? = session.connection else { return }
        checking = true
        defer { checking = false }
        health = await RelayProbe.health(origin)
        capabilities = await RelayProbe.capabilities(origin)
    }
}

/// `GET /relay/health`: no session needed
struct RelayHealth: Decodable {
    let version: String
    let vrchat: String
    let pipeline: Bool
}

/// `GET /relay/v1/capabilities`: what this relay offers phones, asked before
/// signing in. Older relays don't have it, which means neither feature.
struct RelayCapabilities: Decodable {
    struct Features: Decodable {
        let events: Bool
        let push: Bool
        /// VRCX's feed, worked out by the relay (newer relays)
        var feed: Bool?
    }

    struct Events: Decodable {
        let retentionDays: Int?
    }

    let api: Int
    let version: String?
    let features: Features
    let events: Events?
}

enum RelayProbe {
    static func health(_ origin: URL) async -> RelayHealth? {
        await fetch(origin.appending(path: "relay/health"))
    }

    static func capabilities(_ origin: URL) async -> RelayCapabilities? {
        await fetch(origin.appending(path: "relay/v1/capabilities"))
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(VRChatAPI.userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }
}
