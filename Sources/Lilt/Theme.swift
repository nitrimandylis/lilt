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

/// Lyric colours made from an album's palette, tuned to read on a black stage.
/// The most colourful swatch becomes the highlight; the text colours are paler versions of it,
/// so a pink album gives pale pink words, a magenta highlight and a muted pink for sung words.
struct AlbumPalette {
    let text: Color
    let highlight: Color
    let secondary: Color

    /// `hexes` are "rrggbb" strings (Apple gives bgColor and textColor1...4). Nil when empty.
    init?(hexes: [String]) {
        var best: NSColor? = nil
        var bestVividness: CGFloat = -1
        for hex in hexes {
            guard let color = nsColorFromHex(hex) else { continue }
            let vividness = color.saturationComponent * color.brightnessComponent
            if vividness > bestVividness {
                best = color
                bestVividness = vividness
            }
        }
        guard let best else { return nil }

        // Bright enough to glow on black, not so saturated it buzzes.
        let vivid = NSColor(hue: best.hueComponent,
                            saturation: min(best.saturationComponent, 0.85),
                            brightness: max(best.brightnessComponent, 0.8),
                            alpha: 1)
        highlight = Color(nsColor: vivid)
        text = Color(nsColor: vivid.blended(withFraction: 0.65, of: .white) ?? .white)
        secondary = Color(nsColor: (vivid.blended(withFraction: 0.4, of: .white) ?? .white).withAlphaComponent(0.7))
    }
}

/// "rrggbb" to an sRGB NSColor with hue/saturation/brightness available.
func nsColorFromHex(_ hex: String) -> NSColor? {
    guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                   green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255,
                   alpha: 1)
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
