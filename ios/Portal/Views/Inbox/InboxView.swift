import SwiftUI

/// Invites, invite requests, friend requests and group notices
struct InboxView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nothing in Your Inbox",
                systemImage: "tray",
                description: Text("Invites, requests and group notices will show here.")
            )
            .navigationTitle("Inbox")
        }
    }
}
