import AppKit
import SwiftUI

/// The three lyric colours, stored as "#RRGGBBAA" strings in UserDefaults.
enum Theme {
    static let defaultText = "#FFFFFFFF"       // the word being sung
    static let defaultHighlight = "#FFFFFFFF"  // stars, ring, links
    static let defaultSecondary = "#FFFFFFB3"  // words already sung (white at 70%)
}

enum LyricFont: String, CaseIterable, Identifiable {
    case sfPro = "SF Pro"
    case sfRounded = "SF Rounded"
    case newYork = "New York"
    case helveticaNeue = "Helvetica Neue"

    var id: String { rawValue }

    func font(size: CGFloat) -> Font {
        switch self {
        case .sfPro: return .system(size: size, weight: .semibold)
        case .sfRounded: return .system(size: size, weight: .semibold, design: .rounded)
        case .newYork: return .system(size: size, weight: .semibold, design: .serif)
        case .helveticaNeue: return .custom("HelveticaNeue-Medium", size: size)
        }
    }
}

/// "#RRGGBBAA" or "#RRGGBB" to a Color; white if the string is malformed.
func colorFromHex(_ hex: String) -> Color {
    var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if digits.count == 6 { digits += "FF" }
    guard digits.count == 8, let value = UInt64(digits, radix: 16) else { return .white }
    return Color(.sRGB,
                 red: Double((value >> 24) & 0xff) / 255,
                 green: Double((value >> 16) & 0xff) / 255,
                 blue: Double((value >> 8) & 0xff) / 255,
                 opacity: Double(value & 0xff) / 255)
}

func hexFromColor(_ color: Color) -> String {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return Theme.defaultText }
    func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X%02X",
                  byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent), byte(rgb.alphaComponent))
}

/// A Color binding that reads and writes one of the stored hex strings.
func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
    return Binding(
        get: { colorFromHex(hex.wrappedValue) },
        set: { hex.wrappedValue = hexFromColor($0) }
    )
}
