import SwiftUI

/// Press and hold on a friend: open first, then what you can do now, then
/// copy and share
struct FriendMenu: View {
    let friend: Friend
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store
    @Environment(Actions.self) private var actions

    var body: some View {
        Button {
            open(.user(friend.id))
        } label: {
            Label("Open Profile", systemImage: "person.crop.circle")
        }

        let place = friend.place
        let access = store.access(for: friend)
        Section {
            if access == .canJoin {
                Button {
                    Task { await actions.inviteMyself(to: friend.location, worldName: store.world(for: place)?.name) }
                } label: {
                    Label("Send Invite to Myself", systemImage: "paperplane")
                }
            }
            if access != .cannotJoin {
                Button {
                    Task { await actions.requestInvite(from: friend) }
                } label: {
                    Label("Request Invite", systemImage: "hand.raised")
                }
            }
            if let mine = store.myLocation, friend.state != .offline, !store.isWithYou(friend) {
                Button {
                    Task { await actions.invite(friend, to: mine) }
                } label: {
                    Label("Invite to My Instance", systemImage: "envelope")
                }
            }
            if friend.isInGame && place.isInstance {
                Button {
                    open(.instance(friend.location))
                } label: {
                    Label("View Instance", systemImage: "person.3")
                }
                Button {
                    open(.world(place.worldId))
                } label: {
                    Label("View World", systemImage: "globe")
                }
            }
        }

        Section {
            ShareLink(item: VRChatLinks.user(friend.id)) {
                Label("Share Profile", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = friend.name
            } label: {
                Label("Copy Name", systemImage: "textformat")
            }
            Button {
                UIPasteboard.general.string = friend.id
            } label: {
                Label("Copy User ID", systemImage: "number")
            }
            if let link = VRChatLinks.instance(place), friend.isInGame {
                Button {
                    UIPasteboard.general.url = link
                } label: {
                    Label("Copy Instance Link", systemImage: "link")
                }
            }
        }
    }
}

/// Press and hold on a world
struct WorldMenu: View {
    let world: VRCWorld
    let open: (Route) -> Void

    var body: some View {
        Button {
            open(.world(world.id))
        } label: {
            Label("Open World", systemImage: "globe")
        }
        Section {
            ShareLink(item: VRChatLinks.world(world.id)) {
                Label("Share World", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = world.id
            } label: {
                Label("Copy World ID", systemImage: "number")
            }
        }
    }
}
