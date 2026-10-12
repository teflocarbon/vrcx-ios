import SwiftUI

@main
struct PortalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SessionStore
    @State private var friends: FriendsStore
    @State private var actions = Actions()
    @State private var tab = Demo.isOn ? Demo.tab : AppTab.friends

    init() {
        let friends = Demo.isOn ? Demo.friends() : FriendsStore()
        let session = Demo.isOn ? Demo.session(friends: friends) : SessionStore(friends: friends)
        _friends = State(initialValue: friends)
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
                .environment(actions)
                .overlay(alignment: .bottom) { ToastView().environment(actions) }
                .task {
                    actions.attach(session)
                    if Demo.isOn {
                        friends.attach(api: nil, session: session)
                    } else {
                        await session.restore()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        session.startLive()
                        Task { await friends.refreshIfStale() }
                    case .background:
                        session.stopLive()
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
        case .friends, .friend, .world, .signIn: .friends
        case .inbox: .inbox
        case .feed: .feed
        case .you: .you
        }
    }
}
