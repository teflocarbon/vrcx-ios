import SwiftUI

/// One instance of a world: how full it is, who of your friends is there,
/// and a way in. As on the wrist, joining wants details under five minutes
/// old, so you don't send yourself into an instance that's since filled up
/// or closed.
struct InstanceView: View {
    let location: String
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions
    @State private var instance: VRCInstance?
    @State private var updated: Date?
    @State private var error: String?
    @State private var loading = false

    private var place: Location { Location(location) }
    private var world: VRCWorld? { instance?.world ?? store.world(for: place) }
    private static let freshFor: TimeInterval = 5 * 60

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    WorldImage(url: world?.thumbnailImageUrl, cornerRadius: 14)
                        .frame(width: 120, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(world?.name ?? "Instance")
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                        Text("#\(place.instanceName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Badge(place.accessName, color: .accentColor)
                            if place.ageGate {
                                Badge("18+", color: Palette.cannotJoin)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                .onTapGesture { open(.world(place.worldId)) }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                StatsStrip(items: stats)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                joinButton
            } footer: {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(footer)
                }
            }

            let here = store.friends(in: location)
            if !here.isEmpty {
                Section("Friends Here") {
                    ForEach(here) { friend in
                        NavigationLink(value: Route.user(friend.id)) {
                            HStack(spacing: 12) {
                                AvatarView(user: friend.user, size: 36, status: friend.status)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.name).font(.body.weight(.medium))
                                    if let since = friend.locationSince {
                                        Text("\(since.durationSince) in Instance")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .contextMenu {
                            FriendMenu(friend: friend, open: open)
                        }
                    }
                }
            }

            Section("Details") {
                LabeledContent("Region", value: "\(place.regionFlag) \(place.regionName)")
                // Only the platforms someone's on, busiest first: "PC 6 · Android 3"
                let platforms = (instance?.platforms ?? [:])
                    .filter { $0.value > 0 }
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                if !platforms.isEmpty {
                    LabeledContent("Platforms", value: platforms
                        .map { "\(Friend.platformName($0.key) ?? $0.key) \($0.value)" }
                        .joined(separator: " · "))
                }
                if let link = VRChatLinks.instance(place) {
                    ShareLink(item: link) {
                        Label("Share Instance", systemImage: "square.and.arrow.up")
                    }
                }
                CopyRow(label: "Instance ID", value: location)
            }

            if let error {
                Section {
                    ErrorRow(message: error)
                }
            }
        }
        .navigationTitle(world?.name ?? "Instance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task(id: location) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var joinButton: some View {
        let fresh = updated.map { Date().timeIntervalSince($0) < Self.freshFor } ?? false
        let full = instance?.full == true || instance?.hasCapacityForYou == false
        let closed = instance?.closedAt != nil
        Button {
            Task { await actions.inviteMyself(to: location, worldName: world?.name) }
        } label: {
            HStack {
                Label(closed ? "Instance Closed" : full ? "Instance Full" : "Send Invite to Myself", systemImage: "paperplane.fill")
                Spacer()
                if actions.isRunning("self:\(location)") || loading {
                    ProgressView()
                }
            }
        }
        .disabled(!fresh || full || closed || actions.isRunning("self:\(location)"))
    }

    private var footer: String {
        guard let updated else {
            return loading ? "Checking the instance…" : "Couldn't check the instance. Refresh to try again."
        }
        let fresh = Date().timeIntervalSince(updated) < Self.freshFor
        let base = "VRChat sends the invite to you in the game; accept it there to join."
        return fresh ? "\(base) Updated \(updated.shortAgo.lowercased())." : "These details are over five minutes old. Refresh before joining."
    }

    private var stats: [StatsStrip.Item] {
        var items: [StatsStrip.Item] = []
        let capacity = instance?.capacity ?? world?.capacity
        if let people = instance?.people {
            items.append(.init(label: "People", value: capacity.map { "\(people)/\($0)" } ?? "\(people)"))
        } else if let capacity {
            items.append(.init(label: "Capacity", value: "\(capacity)"))
        }
        let friends = store.friends(in: location).count
        items.append(.init(label: "Friends", value: "\(friends)"))
        if let queue = instance?.queueSize, instance?.queueEnabled == true {
            items.append(.init(label: "Queue", value: "\(queue)"))
        }
        items.append(.init(label: "Region", value: place.regionFlag.isEmpty ? place.regionName : place.regionFlag,
                           detail: place.regionFlag.isEmpty ? nil : place.regionName))
        return items
    }

    private func load() async {
        if Demo.isOn {
            var demo = VRCInstance()
            demo.capacity = world?.capacity
            demo.userCount = 9
            demo.platforms = ["standalonewindows": 6, "android": 3]
            instance = demo
            updated = Date()
            return
        }
        guard let api = session.api, place.isInstance else { return }
        loading = true
        defer { loading = false }
        do {
            instance = try await api.get("instances/\(location)")
            updated = Date()
            error = nil
        } catch {
            store.handle(error)
            self.error = error.userMessage
        }
    }
}
