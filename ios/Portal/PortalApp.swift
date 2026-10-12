import SwiftUI

@main
struct PortalApp: App {
    @State private var tab = Demo.isOn ? Demo.tab : AppTab.friends

    enum AppTab: Hashable {
        case friends, inbox, feed, you
    }

    var body: some Scene {
        WindowGroup {
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
}

extension Demo {
    static var tab: PortalApp.AppTab {
        switch screen {
        case .friends: .friends
        case .inbox: .inbox
        case .feed: .feed
        case .you: .you
        }
    }
}
