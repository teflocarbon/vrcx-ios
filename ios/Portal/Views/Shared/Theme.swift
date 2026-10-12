import SwiftUI
import UIKit

// Presence colours: VRChat's own green, blue, orange and red, softened a
// little and deepened for light mode. The wrist's pastels suit glass in VR
// but read as washed out on a phone (seen on a device in October 2026).

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// From "#RRGGBB"
    init?(hex: String?) {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            return nil
        }
        self.init(uiColor: UIColor(hex: value))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Palette {
    static let online = Color(light: 0x2FA35A, dark: 0x4FD27C)
    static let joinMe = Color(light: 0x1F7FD6, dark: 0x45B4F5)
    static let askMe = Color(light: 0xD9781C, dark: 0xF29A3A)
    static let busy = Color(light: 0xD23F4A, dark: 0xF2575F)
    static let offline = Color.secondary

    static let canJoin = Color(light: 0x2E9466, dark: 0x8EDDB4)
    static let canRequest = Color(light: 0xB07D16, dark: 0xE8CB75)
    static let cannotJoin = Color(light: 0xC4455A, dark: 0xEE7D8F)

    /// The wrist's four portrait tones, for people without a picture
    static let tones: [Color] = [
        Color(light: 0x7E9DB8, dark: 0x9CB9D0),
        Color(light: 0x968CB3, dark: 0xB1A8C8),
        Color(light: 0x76A497, dark: 0x95BDB4),
        Color(light: 0xAD9C78, dark: 0xC4B69B),
    ]

    static func tone(for id: String) -> Color {
        // The wrist's hash, so someone has the same colour in VR and on the phone
        let hash = id.unicodeScalars.reduce(Int32(0)) { h, c in h &* 31 &+ Int32(truncatingIfNeeded: c.value) }
        return tones[Int(UInt32(bitPattern: hash) % UInt32(tones.count))]
    }
}

extension UserStatus {
    var color: Color {
        switch self {
        case .joinMe: Palette.joinMe
        case .online: Palette.online
        case .askMe: Palette.askMe
        case .busy: Palette.busy
        case .offline: Palette.offline
        }
    }
}

extension Access {
    var color: Color {
        switch self {
        case .canJoin: Palette.canJoin
        case .canRequest: Palette.canRequest
        case .cannotJoin: Palette.cannotJoin
        }
    }

    var symbol: String {
        switch self {
        case .canJoin: "arrow.right.circle.fill"
        case .canRequest: "hand.raised.fill"
        case .cannotJoin: "lock.fill"
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, frosted material before: for the
    /// floating, controls layer only (cards, rails, banners), never list rows
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// A capsule of glass, tinted when selected: filter chips, status rail
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: .capsule)
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(.ultraThinMaterial), in: .capsule)
        }
    }
}
