import SwiftUI

/// Who's online and where: favourites, joinable, private, not in game, offline
struct FriendsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Friends Yet",
                systemImage: "person.2",
                description: Text("Connect to your relay in You, and your friends will show here with where they are.")
            )
            .navigationTitle("Friends")
        }
    }
}
