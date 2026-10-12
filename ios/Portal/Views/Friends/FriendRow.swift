import SwiftUI

/// A friend in the list: picture, name, status, and where they are, with
/// whether you can get to them, as on the wrist
struct FriendRow: View {
    let friend: Friend
    @Environment(FriendsStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(id: friend.id, name: friend.name, url: friend.user.imageURL, size: 50)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(friend.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if store.isFavourite(friend) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                    Spacer(minLength: 6)
                    if friend.isInGame, friend.place.isInstance, let since = friend.locationSince {
                        // How long they've been there, like a timestamp
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(since.durationSince)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(status: friend.status, hollow: friend.state == .active)
                    Text(statusLine)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                locationLine
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        let message = friend.user.statusDescription?.trimmingCharacters(in: .whitespaces) ?? ""
        if friend.state == .offline {
            if let seen = Date(vrchat: friend.user.lastLogin) ?? friend.stateSince {
                return "Offline · Last Seen \(seen.shortAgo)"
            }
            return "Offline"
        }
        return message.isEmpty ? friend.status.label : message
    }

    @ViewBuilder
    private var locationLine: some View {
        if friend.state != .offline {
            let place = friend.place
            HStack(spacing: 4) {
                Image(systemName: locationSymbol)
                    .imageScale(.small)
                Text(locationText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if friend.isInGame && place.isInstance && !store.isWithYou(friend) {
                    AccessBadge(access: store.access(for: friend))
                } else if store.isWithYou(friend) {
                    Badge("With You", color: .accentColor, symbol: "person.2.fill")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var locationSymbol: String {
        switch friend.state {
        case .active: return "iphone"
        case .offline: return "moon.zzz"
        case .online:
            if friend.place.isPrivate { return "lock" }
            if friend.place.isTraveling { return "arrow.triangle.swap" }
            return "mappin.and.ellipse"
        }
    }

    private var locationText: String {
        var parts = [store.locationText(for: friend)]
        let place = friend.place
        // Next to "With You" the access type says nothing new, and costs room
        if friend.isInGame && place.isInstance && !store.isWithYou(friend) {
            parts.append(place.accessName)
        } else if friend.state == .active, let platform = friend.platformName {
            parts.append(platform)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
