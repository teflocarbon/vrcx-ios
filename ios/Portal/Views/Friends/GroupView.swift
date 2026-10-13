import SwiftUI

/// A group's page: its banner and name, a strip of numbers, its open
/// instances, its latest posts, then what it's about and its details
struct GroupView: View {
    let groupId: String
    let open: (Route) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(FriendsStore.self) private var store
    @Environment(Actions.self) private var actions
    @State private var group: VRCGroupDetail?
    @State private var instances: [VRCGroupInstance] = []
    @State private var posts: [VRCGroupPost] = []
    @State private var error: String?
    @State private var confirmLeave = false

    private var summary: VRCGroup? { group?.summary ?? store.groups[groupId] }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if let group {
                    StatsStrip(items: stats(group))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !instances.isEmpty {
                Section("Live Now") {
                    ForEach(instances) { instance in
                        if let place = instance.place {
                            NavigationLink(value: Route.instance(place)) {
                                InstanceRow(instance: instance, place: place)
                            }
                        }
                    }
                }
            }

            if !posts.isEmpty {
                Section("Latest Posts") {
                    ForEach(posts.prefix(3)) { post in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(post.title ?? "Post")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                if let date = Date(vrchat: post.createdAt) {
                                    Text(date.shortAgo).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let text = post.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                                ExpandableText(text: text, lineLimit: 3)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let description = group?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                Section("About") {
                    ExpandableText(text: description)
                }
            }

            if let rules = group?.rules?.trimmingCharacters(in: .whitespacesAndNewlines), !rules.isEmpty {
                Section("Rules") {
                    ExpandableText(text: rules, lineLimit: 3)
                }
            }

            if let links = group?.links?.compactMap(URL.init(string:)).filter({ $0.scheme == "https" }), !links.isEmpty {
                Section("Links") {
                    ForEach(links, id: \.self) { link in
                        Link(destination: link) {
                            Text(link.absoluteString).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }

            if let group {
                Section("Details") {
                    if let join = group.joinName {
                        LabeledContent("Joining", value: join)
                    }
                    let spoken = (group.languages ?? []).compactMap { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                    if !spoken.isEmpty {
                        LabeledContent("Languages", value: spoken.joined(separator: ", "))
                    }
                    if let created = Date(vrchat: group.createdAt) {
                        LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let joined = Date(vrchat: group.myMember?.joinedAt), group.isMember {
                        LabeledContent("You Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let code = group.summary.code {
                        CopyRow(label: "Short Code", value: code)
                    }
                    CopyRow(label: "Group ID", value: groupId)
                }
            }

            if let error {
                Section { ErrorRow(message: error) }
            }
        }
        .navigationTitle(summary?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    menu
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Leave \(summary?.name ?? "this group")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Group", role: .destructive) { Task { await leave() } }
        } message: {
            Text("You'd need to join again, and some groups only let people in by invite or request.")
        }
        .task(id: groupId) { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = group?.bannerUrl {
                WorldImage(url: VRChatImage.sized(banner, 1024), cornerRadius: 18)
                    .aspectRatio(16 / 6, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 130)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
            }
            HStack(spacing: 14) {
                RemoteImage(url: summary?.iconUrl.map { VRChatImage.sized($0, 512) }) {
                    ZStack {
                        Color.accentColor.opacity(0.2)
                        Image(systemName: "person.3.fill").font(.title2).foregroundStyle(.tint)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(summary?.name ?? "Group")
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        if group?.isVerified == true {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                                .accessibilityLabel("Verified")
                        }
                    }
                    if let code = summary?.code {
                        Text(code).font(.subheadline).foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 6) {
                        if let group {
                            Badge(group.privacyName, color: .accentColor)
                            if group.isMember {
                                Badge("Member", color: Palette.canJoin)
                            }
                            if group.myMember?.isRepresenting == true {
                                Badge("On Your Profile", color: .yellow, symbol: "star.fill")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let group, group.isMember {
            Section {
                Toggle(isOn: Binding(
                    get: { group.myMember?.isRepresenting ?? false },
                    set: { on in Task { await represent(on) } }
                )) {
                    Label("Show on My Profile", systemImage: "person.crop.square")
                }
                Toggle(isOn: Binding(
                    get: { group.myMember?.isSubscribedToAnnouncements ?? true },
                    set: { on in Task { await subscribe(on) } }
                )) {
                    Label("Announcements", systemImage: "bell")
                }
            }
        }
        Section {
            ShareLink(item: VRChatLinks.group(groupId)) {
                Label("Share Group", systemImage: "square.and.arrow.up")
            }
            if let code = summary?.code {
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("Copy Short Code", systemImage: "number")
                }
            }
        }
        if group?.isMember == true {
            Section {
                Button(role: .destructive) {
                    confirmLeave = true
                } label: {
                    Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    private func stats(_ group: VRCGroupDetail) -> [StatsStrip.Item] {
        var items: [StatsStrip.Item] = []
        if let members = group.memberCount {
            items.append(.init(label: "Members", value: members.formatted(.number.notation(.compactName))))
        }
        if let online = group.onlineMemberCount {
            items.append(.init(label: "Online", value: online.formatted(.number.notation(.compactName))))
        }
        items.append(.init(label: "Live", value: "\(instances.count)", color: instances.isEmpty ? nil : Palette.online))
        return items
    }

    // MARK: Loading and changing

    private func load() async {
        if Demo.isOn {
            group = Demo.groupDetail
            instances = Demo.groupInstances
            posts = Demo.groupPosts
            return
        }
        guard let api = session.api else { return }
        do {
            let loaded: VRCGroupDetail = try await api.get("groups/\(groupId)")
            group = loaded
            error = nil
        } catch {
            store.handleSession(error)
            self.error = error.userMessage
            return
        }
        // Members only, and either may be refused: the page works without
        async let live: [VRCGroupInstance]? = try? api.get("groups/\(groupId)/instances")
        async let latest: VRCGroupPosts? = try? api.get("groups/\(groupId)/posts", query: [
            URLQueryItem(name: "n", value: "3"),
            URLQueryItem(name: "offset", value: "0"),
        ])
        instances = (await live ?? []).sorted { ($0.people ?? 0) > ($1.people ?? 0) }
        posts = await latest?.posts ?? []
    }

    private func change(_ success: String, _ work: (VRChatAPI) async throws -> Void) async {
        if Demo.isOn { actions.show(success); return }
        guard let api = session.api else { return }
        do {
            try await work(api)
            actions.show(success)
            await load()
        } catch {
            store.handleSession(error)
            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }

    private func represent(_ on: Bool) async {
        await change(on ? "Shown on your profile" : "Taken off your profile") { api in
            try await api.send("PUT", "groups/\(groupId)/representation", body: ["isRepresenting": on])
        }
    }

    private func subscribe(_ on: Bool) async {
        guard let me = session.me?.id else { return }
        await change(on ? "Announcements on" : "Announcements off") { api in
            try await api.send("PUT", "groups/\(groupId)/members/\(me)", body: ["isSubscribedToAnnouncements": on])
        }
    }

    private func leave() async {
        await change("You left \(summary?.name ?? "the group")") { api in
            try await api.send("POST", "groups/\(groupId)/leave")
        }
    }
}

/// One of a group's open instances: the world, how full, and whether you
/// can get in
private struct InstanceRow: View {
    let instance: VRCGroupInstance
    let place: String
    @Environment(FriendsStore.self) private var store

    var body: some View {
        let location = Location(place)
        let world = instance.world ?? store.world(for: location)
        HStack(spacing: 12) {
            WorldImage(url: world?.thumbnailImageUrl, cornerRadius: 8)
                .frame(width: 72, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(world?.name ?? "World").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([location.accessName, "#\(location.instanceName)", location.regionName]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let people = instance.people {
                Text(world?.capacity.map { "\(people)/\($0)" } ?? "\(people)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
