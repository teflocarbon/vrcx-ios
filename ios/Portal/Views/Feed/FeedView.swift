import SwiftUI

/// What your friends have been doing: online, offline, moving between worlds
struct FeedView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "list.bullet.rectangle.portrait",
                description: Text("When friends come online, change worlds or update their status, it will show here.")
            )
            .navigationTitle("Feed")
        }
    }
}
