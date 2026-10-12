import SwiftUI

/// The wrist's connection banners, as a glass card at the top of a list:
/// signed out at the relay, live updates paused, or a failed refresh
struct ConnectionBanner: View {
    @Environment(SessionStore.self) private var session
    @Environment(FriendsStore.self) private var store

    var body: some View {
        if let banner {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: banner.symbol)
                        .font(.title3)
                        .foregroundStyle(banner.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title).font(.subheadline.weight(.semibold))
                        Text(banner.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassSurface(cornerRadius: 20)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
    }

    private struct Info {
        let title: String
        let detail: String
        let symbol: String
        let color: Color
    }

    private var banner: Info? {
        if session.relaySignedOut {
            return Info(
                title: "Relay Signed Out",
                detail: "Your relay has lost its VRChat session. Sign it in again from its admin page, and Portal will carry on.",
                symbol: "person.crop.circle.badge.exclamationmark",
                color: .orange
            )
        }
        if let error = store.error, !store.friends.isEmpty {
            return Info(title: "Couldn't Refresh", detail: error, symbol: "wifi.exclamationmark", color: .orange)
        }
        switch session.pipelineState {
        case .waiting:
            return Info(
                title: "Updates Paused",
                detail: "Portal lost its live connection and is trying again. What you see may be out of date.",
                symbol: "pause.circle.fill",
                color: Palette.askMe
            )
        default:
            return nil
        }
    }
}
