import SwiftUI

/// Someone's profile, App Store style: a header with the one thing you'd
/// most likely do, a strip of facts, where they are, then their bio and
/// details
struct UserView: View {
    let userId: String
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions
    @State private var profile: VRCUser?
    @State private var error: String?

    private var friend: Friend? { store.friends[userId] }

    /// The freshest of what the list knows and the profile page fetched
    private var user: VRCUser {
        let base = profile ?? friend?.user ?? VRCUser(id: userId)
        guard let live = friend?.user, profile != nil else { return base }
        // Live status from the pipeline beats a profile fetched a while ago
        var merged = base
        merged.status = live.status ?? base.status
        merged.statusDescription = live.statusDescription ?? base.statusDescription
        return merged
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                StatsStrip(items: stats)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let friend, friend.isInGame {
                Section("Where They Are") {
                    LocationCard(friend: friend, open: open)
                }
            }

            if let message = user.statusDescription, !message.isEmpty {
                Section("Status") {
                    Text(message)
                }
            }

            if let bio = user.bio, !bio.isEmpty {
                Section("Bio") {
                    ExpandableText(text: bio)
                }
            }

            Section("Details") {
                if let pronouns = user.pronouns, !pronouns.isEmpty {
                    LabeledContent("Pronouns", value: pronouns)
                }
                let spoken = languages(from: user.tags)
                if !spoken.isEmpty {
                    LabeledContent("Languages", value: spoken.joined(separator: ", "))
                }
                if let groups = store.favouriteGroups[userId], !groups.isEmpty {
                    LabeledContent("Favourite Groups", value: groups.joined(separator: ", "))
                }
                if let platform = Friend.platformName(friend?.platform ?? user.lastPlatform) {
                    LabeledContent("Last Platform", value: platform)
                }
                if let joined = Date(vrchat: user.dateJoined) ?? Self.day(user.dateJoined) {
                    LabeledContent("Joined VRChat", value: joined.formatted(date: .abbreviated, time: .omitted))
                }
                if let note = user.note, !note.isEmpty {
                    LabeledContent("Your Note", value: note)
                }
                CopyRow(label: "User ID", value: userId)
            }

            if let links = user.bioLinks, !links.isEmpty {
                Section("Links") {
                    ForEach(links, id: \.self) { link in
                        if let url = URL(string: link) {
                            Link(destination: url) {
                                Text(link).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }

            if let error {
                Section {
                    ErrorRow(message: error)
                }
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let friend {
                    Menu {
                        FriendMenu(friend: friend, open: open)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                } else {
                    ShareLink(item: VRChatLinks.user(userId))
                }
            }
        }
        .task(id: userId) { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AvatarView(id: userId, name: user.name, url: user.largeImageURL, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(user.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                if let friend {
                    HStack(spacing: 6) {
                        StatusDot(status: friend.status, hollow: friend.state == .active)
                        Text(presenceText(friend))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    if friend != nil {
                        Badge("Friend", color: .accentColor)
                    }
                    if friend.map(store.isFavourite) ?? false {
                        Badge("Favourite", color: .yellow, symbol: "star.fill")
                    }
                    if let friend, store.isWithYou(friend) {
                        Badge("In Your Instance", color: Palette.canJoin)
                    }
                }
                primaryButton
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let friend {
            let access = store.access(for: friend)
            if access == .canJoin {
                Button {
                    Task { await actions.inviteMyself(to: friend.location, worldName: store.world(for: friend.place)?.name) }
                } label: {
                    Text("Join").frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(actions.isRunning("self:\(friend.location)"))
            } else if access == .canRequest {
                Button {
                    Task { await actions.requestInvite(from: friend) }
                } label: {
                    Text("Request Invite")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(actions.isRunning("request:\(friend.id)"))
            }
        }
    }

    private var stats: [StatsStrip.Item] {
        var items: [StatsStrip.Item] = []
        if let friend {
            items.append(.init(label: "Status", value: friend.status.label, detail: friend.state == .active ? "Not in game" : nil,
                               color: friend.status == .offline ? nil : friend.status.color))
        }
        let trust = TrustRank(tags: user.tags)
        items.append(.init(label: "Trust", value: trust.name, color: trust.color))
        if let friend, friend.isInGame, let since = friend.locationSince {
            items.append(.init(label: "Here For", value: since.durationSince, detail: "in this instance"))
        } else if let friend, friend.state == .offline, let seen = Date(vrchat: user.lastLogin) {
            items.append(.init(label: "Last Seen", value: seen.shortAgo))
        }
        if let platform = Friend.platformName(friend?.platform ?? user.lastPlatform) {
            items.append(.init(label: "Platform", value: platform))
        }
        return items
    }

    private func presenceText(_ friend: Friend) -> String {
        switch friend.state {
        case .online: friend.status.label
        case .active: "\(friend.status.label) · Not In Game"
        case .offline: "Offline"
        }
    }

    private func load() async {
        if Demo.isOn { return }
        guard let api = session.api else { return }
        do {
            profile = try await api.get("users/\(userId)")
            error = nil
        } catch {
            store.handle(error)
            self.error = error.userMessage
        }
    }

    /// "2021-03-14", which VRChat uses for when someone joined
    private static func day(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

/// Where a friend is, as a card: the world's picture, its name, the
/// instance's access and region, and whether you can join
struct LocationCard: View {
    let friend: Friend
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store

    var body: some View {
        let place = friend.place
        let world = store.world(for: place)
        Button {
            if place.isInstance { open(.instance(friend.location)) }
        } label: {
            HStack(spacing: 12) {
                WorldImage(url: world?.thumbnailImageUrl, cornerRadius: 10)
                    .frame(width: 96, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.locationText(for: friend))
                        .font(.headline)
                        .lineLimit(2)
                    if place.isInstance {
                        Text([place.accessName, "\(place.regionFlag) \(place.regionName)", "#\(place.instanceName)"]
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            .joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if store.isWithYou(friend) {
                            Badge("With You", color: .accentColor, symbol: "person.2.fill")
                        } else {
                            AccessBadge(access: store.access(for: friend))
                        }
                    }
                }
                Spacer(minLength: 0)
                if place.isInstance {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tint(.primary)
        .disabled(!place.isInstance)
    }
}
