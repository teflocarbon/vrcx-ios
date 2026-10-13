import SwiftUI
import UserNotifications

@main
struct PortalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionStore
    @State private var friends: FriendsStore
    @State private var inbox: InboxStore
    @State private var feed: FeedStore
    @State private var push: PushStore
    @State private var history: NotificationHistoryStore
    @State private var links = DeepLinks.shared
    @State private var actions = Actions()
    @State private var tab = Demo.isOn ? Demo.tab : AppTab.friends

    init() {
        let friends = Demo.isOn ? Demo.friends() : FriendsStore()
        let inbox = Demo.isOn ? Demo.inbox() : InboxStore()
        let feed = Demo.isOn ? Demo.feed() : FeedStore()
        let push = Demo.isOn ? PushStore(demo: true) : PushStore()
        let history = Demo.isOn ? Demo.history() : NotificationHistoryStore()
        let session = Demo.isOn
            ? Demo.session(friends: friends, inbox: inbox, feed: feed)
            : SessionStore(friends: friends, inbox: inbox, feed: feed)
        _friends = State(initialValue: friends)
        _inbox = State(initialValue: inbox)
        _feed = State(initialValue: feed)
        _push = State(initialValue: push)
        _history = State(initialValue: history)
        session.history = history
        AppDelegate.push = push
        session.push = push
        _session = State(initialValue: session)
    }

    enum AppTab: Hashable {
        case friends, inbox, feed, you
    }

    var body: some Scene {
        WindowGroup {
            root
                .environment(session)
                .environment(friends)
                .environment(inbox)
                .environment(feed)
                .environment(push)
                .environment(history)
                .environment(actions)
                .overlay(alignment: .bottom) { ToastView().environment(actions) }
                .task {
                    actions.attach(session)
                    push.attach(session)
                    history.attach(session)
                    session.onArrival = { item in
                        let name = item.senderName ?? "Someone"
                        actions.show("\(name): \(item.headline(worldName: nil))", symbol: "tray.and.arrow.down.fill")
                    }
                    if Demo.isOn {
                        friends.attach(api: nil, session: session)
                        inbox.attach(session)
                        feed.attach(session)
                    } else {
                        await session.restore()
                    }
                }
                .onChange(of: session.phase) { _, phase in
                    if phase == .signedIn { Task { await push.setUp() } }
                }
                .onChange(of: links.pending) { _, destination in
                    switch destination {
                    case .inbox:
                        tab = .inbox
                        links.pending = nil
                    case .you:
                        tab = .you
                        links.pending = nil
                    case .user:
                        // Friends opens the profile, then clears it
                        tab = .friends
                    case nil:
                        break
                    }
                }
                .onChange(of: inbox.unreadCount) { _, count in
                    UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        session.startLive()
                        Task { await friends.refreshIfStale() }
                        Task { await inbox.refreshIfStale() }
                        // Catches the feed up from where it got to, however long it's been
                        Task { await feed.refresh() }
                        Task { await history.refresh() }
                    case .background:
                        session.stopLive()
                        BackgroundCheck.schedule()
                    default:
                        break
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch session.phase {
        case .restoring:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn:
            if Demo.isOn && Demo.screen == .signIn {
                SignInView()
            } else {
                tabs
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(AppTab.friends)
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .badge(inbox.unreadCount)
                .tag(AppTab.inbox)
            FeedView()
                .tabItem { Label("Feed", systemImage: "list.bullet.rectangle.portrait.fill") }
                .tag(AppTab.feed)
            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
                .tag(AppTab.you)
        }
    }
}

/// A short message after an action, floating above the tab bar
private struct ToastView: View {
    @Environment(Actions.self) private var actions

    var body: some View {
        Group {
            if let toast = actions.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                        .foregroundStyle(toast.failed ? Color.orange : Palette.canJoin)
                    Text(toast.text)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassSurface(cornerRadius: 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .onTapGesture { actions.dismissToast() }
            }
        }
        .animation(.snappy, value: actions.toast)
    }
}

extension Demo {
    static var tab: PortalApp.AppTab {
        switch screen {
        case .friends, .friend, .world, .group, .signIn: .friends
        case .inbox, .history: .inbox
        case .feed: .feed
        case .you: .you
        }
    }
}
