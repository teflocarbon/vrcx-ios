import SwiftUI

/// Push notifications: whether they're on, what for, and for which friends
/// coming online. The choices live on the relay, so they apply while
/// Portal is closed.
struct NotificationsView: View {
    @Environment(PushStore.self) private var push
    @Environment(FriendsStore.self) private var friends
    @Environment(\.openURL) private var openURL
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        List {
            switch push.availability {
            case .unknown:
                Section {
                    HStack {
                        ProgressView()
                        Text("Checking your relay…").foregroundStyle(.secondary)
                    }
                }
            case .needsRelay:
                BackgroundCheckSection()
            case .relayNotSetUp:
                Section {
                    ContentUnavailableView(
                        "Relay Not Set Up for Push",
                        systemImage: "bell.slash",
                        description: Text("Your relay needs an APNs key from your Apple developer account. Its README says how; once it has one, come back here.")
                    )
                }
            case .available:
                available
            }

            if let error = push.error {
                Section {
                    ErrorRow(message: error)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await push.setUp() }
    }

    @ViewBuilder
    private var available: some View {
        switch push.permission {
        case .denied:
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("Notifications are off for Portal in Settings. Turn them on there, then come back.")
            }
        case .authorized, .provisional, .ephemeral:
            if push.device == nil {
                Section {
                    HStack {
                        ProgressView()
                        Text(push.registering ? "Registering this phone…" : "Waiting for iOS…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                choices
            }
        default:
            Section {
                Button("Turn On Notifications…") {
                    Task { await push.turnOn() }
                }
            } footer: {
                Text("Your relay will tell you about invites, requests and friends coming online, even while Portal is closed. What's sent passes through Apple, so it's kept short: names and worlds, never messages or bios.")
            }
        }
    }

    @ViewBuilder
    private var choices: some View {
        Section {
            ForEach(PushStore.Kind.allCases.filter { $0 != .friendOnline }) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { push.wants(kind) },
                    set: { on in Task { await push.set(kind, on: on) } }
                ))
            }
        } header: {
            Text("Notify Me About")
        } footer: {
            Text("Invites and invite requests can break through Focus, as they don't wait.")
        }

        Section {
            Toggle(PushStore.Kind.friendOnline.title, isOn: Binding(
                get: { push.wants(.friendOnline) },
                set: { on in Task { await push.set(.friendOnline, on: on) } }
            ))
            if push.wants(.friendOnline) {
                NavigationLink {
                    OnlineFriendsPicker()
                } label: {
                    LabeledContent("Friends", value: onlineSummary)
                }
            }
        } footer: {
            Text("Only for the friends you choose. Coming back within a few minutes of going offline doesn't count, as in VRCX. You can also choose from a friend's menu.")
        }

        Section {
            Toggle("Quiet While I'm in VR", isOn: Binding(
                get: { push.device?.quietWhileInVR ?? false },
                set: { on in Task { await push.setQuietWhileInVR(on) } }
            ))
        } footer: {
            Text("Holds notifications while the game is running on your PC, since the wrist already shows them. This needs Teflokit to tell your relay when you're playing; until it does, this has no effect.")
        }

        Section {
            Button {
                Task {
                    testing = true
                    testResult = await push.sendTest()
                    testing = false
                }
            } label: {
                HStack {
                    Text("Send Test Notification")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)
        } footer: {
            if let testResult {
                Text(testResult)
            }
        }
    }

    private var onlineSummary: String {
        let count = push.device?.friendsOnline?.count ?? 0
        switch count {
        case 0: return "None"
        case 1:
            let id = push.device?.friendsOnline?.first ?? ""
            return friends.friends[id]?.name ?? "1 Friend"
        default: return "\(count) Friends"
        }
    }
}

/// Which friends coming online gets a notification
private struct OnlineFriendsPicker: View {
    @Environment(PushStore.self) private var push
    @Environment(FriendsStore.self) private var friends
    @State private var search = ""

    var body: some View {
        let all = friends.friends.values
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                let af = friends.isFavourite(a), bf = friends.isFavourite(b)
                if af != bf { return af }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        List {
            Section {
                ForEach(all) { friend in
                    let on = push.notifiesOnline(friend.id)
                    Button {
                        Task { await push.setOnline(friend.id, on: !on) }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(user: friend.user, size: 34)
                            Text(friend.name)
                            if friends.isFavourite(friend) {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                            Spacer()
                            if on {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("Favourites first.")
            }
        }
        .searchable(text: $search, prompt: "Find a Friend")
        .navigationTitle("Friends Coming Online")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Signed in to VRChat directly there's no relay to push, so the best iOS
/// offers is a check now and then. Said plainly, so nobody expects live.
private struct BackgroundCheckSection: View {
    @Environment(PushStore.self) private var push
    @State private var on = BackgroundCheck.isOn

    var body: some View {
        Section {
            Toggle("Check for Invites in the Background", isOn: $on)
                .onChange(of: on) { _, value in
                    BackgroundCheck.isOn = value
                    if value { Task { await push.turnOnLocal() } }
                }
        } header: {
            Text("Without a Relay")
        } footer: {
            Text("iOS wakes Portal now and then to look for invites, invite requests and friend requests, and Portal tells you about new ones. iOS decides when: often a few times an hour, less on low battery, and never after you swipe Portal away. For notifications the moment something happens, connect to a VRCX relay.")
        }
        if push.permission == .denied && on {
            Section {
                ErrorRow(message: "Notifications are off for Portal in Settings, so these can't show.")
            }
        }
    }
}
