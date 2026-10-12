import SwiftUI

/// You: your status and message, where you are, and Portal's settings
struct YouView: View {
    @Environment(SessionStore.self) private var session
    @Environment(FriendsStore.self) private var store
    @State private var path: [Route] = []
    @Environment(PushStore.self) private var push

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let me = session.me {
                    Section {
                        ProfileHeader(me: me)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    StatusMessageSection(me: me)
                    if let location = me.location {
                        Section("Where You Are") {
                            MyLocationRow(location: location) { path.append($0) }
                        }
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading your profile…").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        ConnectionView()
                    } label: {
                        LabeledContent {
                            Text(session.connection?.displayName ?? "")
                        } label: {
                            IconText(symbol: session.connection?.isRelay == true ? "server.rack" : "globe", text: session.connection?.isRelay == true ? "Relay" : "VRChat")
                        }
                    }
                    LabeledContent("Live Updates", value: liveText)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Live updates run while Portal is open. iOS stops them soon after you leave, and Portal catches up when you come back.")
                }

                Section {
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        LabeledContent {
                            Text(push.isOn ? "On" : BackgroundCheck.isOn ? "Background Checks" : "Off")
                        } label: {
                            IconText(symbol: "bell.badge", text: "Notifications")
                        }
                    }
                } footer: {
                    Text("Invites, requests and friends coming online, from your relay, even while Portal is closed.")
                }

                Section {
                    Picker("Favourites at the Top", selection: Bindable(store).favouritesGroup) {
                        Text("All Favourites").tag(String?.none)
                        ForEach(store.favouriteGroupList) { group in
                            Text(group.displayName ?? group.name).tag(Optional(group.name))
                        }
                    }
                    Toggle("Show Offline Favourites", isOn: Bindable(store).showOfflineFavourites)
                } header: {
                    Text("Friends")
                } footer: {
                    Text("Choose one of your VRChat favourite groups to keep at the top of Friends, as the wrist does. With Show Offline Favourites on, they stay there when they're offline too; everyone else's favourites sit with the rest.")
                }

                Section("Developer") {
                    NavigationLink("Network Log") { NetworkLogView() }
                    NavigationLink("Live Events") { EventLogView() }
                }

                Section("About") {
                    LabeledContent("Version", value: BuildInfo.versionText)
                    if let commit = BuildInfo.commit {
                        LabeledContent("Commit", value: commit)
                            .textSelection(.enabled)
                    }
                    Link(destination: URL(string: "https://github.com/teflocarbon/vrcx-ios")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                Section {
                } footer: {
                    Text("Portal is unofficial, and isn't made or endorsed by VRChat or the VRCX team.")
                }
            }
            .navigationTitle("You")
            .refreshable { await session.refresh() }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, path: $path)
            }
        }
    }

    private var liveText: String {
        switch session.pipelineState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .waiting: "Reconnecting…"
        case .stopped: "Paused"
        }
    }
}

private struct ProfileHeader: View {
    let me: CurrentUser

    var body: some View {
        HStack(spacing: 16) {
            AvatarView(user: me.asUser, size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(me.displayName ?? "You")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                let trust = TrustRank(tags: me.tags)
                Text(trust.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(trust.color)
                StatusPill(me: me)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Your status as a small glass pill under your name: tap for the four,
/// each with its colour, like the Focus picker
private struct StatusPill: View {
    let me: CurrentUser
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions
    @State private var setting: UserStatus?

    var body: some View {
        let current = UserStatus(me.status)
        Menu {
            Picker("Status", selection: Binding(
                get: { setting ?? current },
                set: { status in Task { await set(status) } }
            )) {
                ForEach(UserStatus.choosable, id: \.self) { status in
                    Label {
                        Text(status.label)
                    } icon: {
                        // Menus draw icons as templates: a pre-coloured
                        // image keeps the status colour
                        Image(uiImage: Self.dot(status))
                    }
                    .tag(status)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if setting != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(status: current, size: 9)
                }
                Text((setting ?? current).label)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // The same solid capsule as the filter chips
            .background(.fill.tertiary, in: Capsule())
        }
        // Menus tint their label: only the dot should carry colour
        .tint(.primary)
        .disabled(setting != nil)
        .accessibilityLabel("Status: \(current.label)")
    }

    private static func dot(_ status: UserStatus) -> UIImage {
        let image = UIImage(systemName: "circle.fill") ?? UIImage()
        return image.withTintColor(UIColor(status.color), renderingMode: .alwaysOriginal)
    }

    private func set(_ status: UserStatus) async {
        guard status != UserStatus(me.status) else { return }
        setting = status
        defer { setting = nil }
        do {
            try await session.setStatus(status, message: me.statusDescription ?? "")
        } catch {
            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }
}

/// Your status message, 32 characters at most, with your recent ones a tap
/// away
private struct StatusMessageSection: View {
    let me: CurrentUser
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    private static let limit = 32

    var body: some View {
        Section {
            HStack {
                TextField("What are you up to?", text: $draft)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .onChange(of: draft) { _, value in
                        if value.count > Self.limit { draft = String(value.prefix(Self.limit)) }
                    }
                if saving {
                    ProgressView()
                } else if focused || draft != (me.statusDescription ?? "") {
                    Text("\(Self.limit - draft.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let history = me.statusHistory?.filter({ !$0.isEmpty && $0 != draft }), !history.isEmpty {
                Menu {
                    ForEach(history.prefix(10), id: \.self) { message in
                        Button(message) {
                            draft = message
                            Task { await save() }
                        }
                    }
                } label: {
                    Label("Recent Messages", systemImage: "clock.arrow.circlepath")
                }
            }
        } header: {
            Text("Status Message")
        } footer: {
            if draft != (me.statusDescription ?? "") {
                Button("Save") { Task { await save() } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .onAppear { draft = me.statusDescription ?? "" }
        .onChange(of: me.statusDescription) { _, value in
            if !focused { draft = value ?? "" }
        }
    }

    private func save() async {
        focused = false
        guard draft != (me.statusDescription ?? "") else { return }
        saving = true
        defer { saving = false }
        do {
            try await session.setStatus(UserStatus(me.status), message: draft)
            actions.show("Status message updated")
        } catch {
            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }
}

private struct MyLocationRow: View {
    let location: String
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store

    var body: some View {
        let place = Location(location)
        let world = store.world(for: place)
        let friends = store.friends(in: location).count
        Button {
            open(.instance(location))
        } label: {
            HStack(spacing: 12) {
                WorldImage(url: world?.thumbnailImageUrl, cornerRadius: 10)
                    .frame(width: 96, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(world?.name ?? "Loading World…")
                        .font(.headline)
                    Text("\(place.accessName) · \(place.regionFlag) \(place.regionName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if friends > 0 {
                        Text(friends == 1 ? "1 Friend Here" : "\(friends) Friends Here")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .onAppear { store.requestWorld(place.worldId) }
    }
}
