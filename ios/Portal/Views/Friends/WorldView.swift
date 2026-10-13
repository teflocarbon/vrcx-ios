import SwiftUI

/// A world's page: its picture, a strip of numbers, which friends are
/// there, its description, then details
struct WorldView: View {
    let worldId: String
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var store
    @State private var loaded: VRCWorld?
    @State private var error: String?

    private var world: VRCWorld? { loaded ?? store.worlds[worldId] }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    WorldImage(url: world?.imageUrl ?? world?.thumbnailImageUrl, cornerRadius: 18)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(world?.name ?? "World")
                            .font(.title2.weight(.bold))
                        if let author = world?.authorName {
                            Text("by \(author)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let world {
                    StatsStrip(items: stats(world))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            let here = store.friends(inWorld: worldId)
            if !here.isEmpty {
                Section("Friends Here") {
                    ForEach(here) { friend in
                        Button {
                            open(.instance(friend.location))
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(user: friend.user, size: 36, status: friend.status)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.name).font(.body.weight(.medium))
                                    Text("\(friend.place.accessName) · #\(friend.place.instanceName)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                AccessBadge(access: store.access(for: friend))
                            }
                        }
                        .tint(.primary)
                        .contextMenu {
                            FriendMenu(friend: friend, open: open)
                        }
                    }
                }
            }

            if let description = world?.description, !description.isEmpty {
                Section("Description") {
                    ExpandableText(text: description)
                }
            }

            if let world {
                Section("Details") {
                    if let capacity = world.capacity {
                        LabeledContent("Capacity", value: world.recommendedCapacity.map { "\(capacity) (\($0) recommended)" } ?? "\(capacity)")
                    }
                    if let published = Date(vrchat: world.publicationDate) ?? Date(vrchat: world.createdAt) {
                        LabeledContent("Published", value: published.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let updated = Date(vrchat: world.updatedAt) {
                        LabeledContent("Updated", value: updated.formatted(date: .abbreviated, time: .omitted))
                    }
                    CopyRow(label: "World ID", value: world.id)
                }
            }

            if let error {
                Section {
                    ErrorRow(message: error)
                }
            }
        }
        .navigationTitle(world?.name ?? "World")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: VRChatLinks.world(worldId))
            }
        }
        .task(id: worldId) { await load() }
        .refreshable { await load() }
    }

    private func stats(_ world: VRCWorld) -> [StatsStrip.Item] {
        var items: [StatsStrip.Item] = []
        if let occupants = world.occupants {
            items.append(.init(label: "Players", value: occupants.formatted(), detail: "right now"))
        }
        if let favourites = world.favorites {
            items.append(.init(label: "Favourites", value: favourites.formatted(.number.notation(.compactName))))
        }
        if let visits = world.visits {
            items.append(.init(label: "Visits", value: visits.formatted(.number.notation(.compactName))))
        }
        if let capacity = world.capacity {
            items.append(.init(label: "Capacity", value: "\(capacity)", detail: "people"))
        }
        return items
    }

    private func load() async {
        do {
            loaded = try await store.loadWorld(worldId)
            error = nil
        } catch {
            store.handleSession(error)
            if world == nil { self.error = error.userMessage }
        }
    }
}
