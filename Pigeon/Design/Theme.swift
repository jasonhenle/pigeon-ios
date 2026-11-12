import Observation
import SwiftUI

/// The app's accent color: the theme color of the selected Pigeon, so the app matches its screen.
///
/// Each Pigeon's color is remembered (by device id) the last time the app read its settings;
/// `follow` switches the app to one of them. Views read `Theme.accent`, and because this is
/// `@Observable` they redraw when it changes.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    /// The Pigeon theme colors as the app draws them, keyed as the device names them.
    static let colors: [String: UInt32] = [
        "blue": 0x4EA6F7, "green": 0x00A32E, "yellow": 0xE6FF0A, "pink": 0xFF5CA8,
        "red": 0xFF0000, "white": 0xFFFFFF, "orange": 0xE39F00, "grey": 0x777777,
    ]
    static let defaultKey = "blue"

    private(set) var accentKey: String
    var accent: Color { Self.color(for: accentKey) }
    /// Black reads better than white on a filled accent shape, in every theme color.
    var onAccent: Color { .black }

    @ObservationIgnored private let defaults: UserDefaults
    /// Each Pigeon's color, as last read from it (the Devices list shows it as a dot).
    private var byDevice: [String: String]
    @ObservationIgnored private var following: String?
    private enum Keys {
        static let accent = "theme_accent"
        static let byDevice = "theme_accent_by_device"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentKey = defaults.string(forKey: Keys.accent) ?? Self.defaultKey
        byDevice = defaults.dictionary(forKey: Keys.byDevice) as? [String: String] ?? [:]
    }

    static func color(for key: String) -> Color { Color(hex: colors[key] ?? colors[defaultKey]!) }

    /// The key to show for a device's settings: its theme color, or red in the old dark mode.
    static func key(for settings: PigeonSettings) -> String {
        if settings.options["color_format"] == "dark" { return "red" }
        return settings.uiColor ?? defaultKey
    }

    func key(for deviceID: String) -> String? { byDevice[deviceID] }

    /// Remember a Pigeon's color; the app takes it on at once if it is following that Pigeon.
    func remember(_ key: String, for deviceID: String) {
        guard Self.colors[key] != nil else { return }
        if byDevice[deviceID] != key {
            byDevice[deviceID] = key
            defaults.set(byDevice, forKey: Keys.byDevice)
        }
        if following == deviceID { apply(key) }
    }

    /// Wear this Pigeon's color while its pages are open. `nil` (the Devices list, adding a Pigeon):
    /// belongs to no Pigeon, so back to Pigeon blue.
    func follow(_ deviceID: String?) {
        following = deviceID
        apply(deviceID.flatMap { byDevice[$0] } ?? (deviceID == nil ? Self.defaultKey : accentKey))
    }

    func forget(_ deviceID: String) {
        byDevice[deviceID] = nil
        defaults.set(byDevice, forKey: Keys.byDevice)
    }

    private func apply(_ key: String) {
        guard key != accentKey else { return }
        accentKey = key
        defaults.set(key, forKey: Keys.accent)
    }
}

/// Design tokens taken from PigeonOS (settings pages): black canvas, #231F20 tiles,
/// the Pigeon's theme color as the accent, Digital-7 for LCD-style labels, Sharp Sans for UI text.
enum Theme {
    static let canvas = Color.black
    static let tile = Color(hex: 0x231F20)
    static let tileRaised = Color(hex: 0x2E2A2B)
    static let inactive = Color(hex: 0x404040)
    static var accent: Color { ThemeStore.shared.accent }
    static let ok = Color(hex: 0x58FF00)
    static let bad = Color(hex: 0xFF0000)
    static let secondaryText = Color(hex: 0x9A9A9A)

    static let corner: CGFloat = 16
    static let gutter: CGFloat = 16

    static func lcd(_ size: CGFloat) -> Font { .custom("Digital-7", size: size) }
    static func ui(_ size: CGFloat) -> Font { .custom("SharpSans-Medium", size: size) }
    static func uiBold(_ size: CGFloat) -> Font { .custom("SharpSans-Semibold", size: size) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct TileBackground: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(selected ? Color.white : .clear, lineWidth: 3)
            )
    }
}

extension View {
    func tile(selected: Bool = false) -> some View { modifier(TileBackground(selected: selected)) }
}

struct LCDLabel: View {
    let text: String
    var size: CGFloat = 20
    var color: Color = .white
    var body: some View {
        Text(text.uppercased()).font(Theme.lcd(size)).foregroundStyle(color)
    }
}
