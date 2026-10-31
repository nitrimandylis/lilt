import AppKit
import SwiftUI

/// Every lyric style Lilt can draw. The raw value is what the menu shows.
enum LyricStyle: String, CaseIterable, Identifiable {
    case constellation = "Constellation"
    case ship = "Ship"
    case codestyle = "Codestyle"

    var id: String { rawValue }
}

/// The three lyric colours after Auto Sync has had its say.
struct LyricColors {
    var text: Color
    var highlight: Color
    var secondary: Color
}

/// Picks the style from settings and shows it. Both the lock screen and the lyrics window use this.
struct LyricsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    @AppStorage("lyricStyle") private var styleChoice = LyricStyle.constellation.rawValue

    var body: some View {
        switch LyricStyle(rawValue: styleChoice) ?? .constellation {
        case .constellation:
            ConstellationView(model: model, player: player)
        case .ship:
            WallView(model: model, player: player)
        case .codestyle:
            CodeView(model: model, player: player)
        }
    }
}

/// Settings every style reads: colours (with Auto Sync), font, and the song clock with delay applied.
struct StyleSettings {
    @AppStorage("textColor") var textHex = Theme.defaultText
    @AppStorage("highlightColor") var highlightHex = Theme.defaultHighlight
    @AppStorage("secondaryColor") var secondaryHex = Theme.defaultSecondary
    @AppStorage("autoSyncColors") var autoSync = true
    @AppStorage("lyricFont") var fontChoice = LyricFont.sfPro.rawValue
    @AppStorage("lyricsDelay") var delay = 0.0

    func colors(palette: AlbumPalette?) -> LyricColors {
        if autoSync, let palette {
            return LyricColors(text: palette.text, highlight: palette.highlight, secondary: palette.secondary)
        }
        return LyricColors(text: colorFromHex(textHex), highlight: colorFromHex(highlightHex), secondary: colorFromHex(secondaryHex))
    }

    var font: LyricFont { LyricFont(rawValue: fontChoice) ?? .sfPro }

    /// Song time for the animation; positive delay holds the lyrics back to match what you hear.
    @MainActor func songTime(player: PlayerMonitor, model: AppModel, at date: Date) -> Double {
        return player.position(at: date) - delay - model.outputDelay
    }
}

// MARK: - Ship

/// Ship: the words sung so far stack into a ragged wall, newest at the bottom, that slowly
/// yaws, pitches and breathes in 3D. Some words sit on a coloured band.
///
/// Studied from Verci's decompiled Ship branch, written fresh here:
/// - only the last 5 words that have started are shown; each pops in with a quick spring;
/// - a held word is bigger: size grows with the square root of its length against the line average;
/// - every word gets a fixed random tilt (up to 4.5 degrees) and indent, and about 1 in 5 gets a band;
/// - the wall drifts on the wall clock: yaw 16 degrees, pitch 7 degrees, scale 3.5%, all slow sines.
struct WallView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    var settings = StyleSettings()

    var body: some View {
        TimelineView(.animation) { timeline in
            WallScene(lines: model.lyrics?.lines ?? [],
                      songTime: settings.songTime(player: player, model: model, at: timeline.date),
                      clock: timeline.date.timeIntervalSinceReferenceDate,
                      colors: settings.colors(palette: model.palette),
                      font: settings.font)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

/// One frame of the Ship wall, from plain values (so the preview can draw it without music).
struct WallScene: View {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double
    let colors: LyricColors
    let font: LyricFont

    let visibleWords = 5
    let lineHold = 0.8  // seconds a line stays up after its last word ends

    var body: some View {
        GeometryReader { geometry in
            wall(size: geometry.size)
        }
    }

    private func wall(size: CGSize) -> some View {
        let words = startedWords()
        let wallHeight = size.height * 0.56

        return VStack(alignment: .leading, spacing: -0.012 * wallHeight) {
            ForEach(words.indices, id: \.self) { position in
                let item = words[position]
                WallWord(text: item.word.text, id: item.id, fontSize: fontSize(item, wallHeight: wallHeight, width: size.width),
                         newest: position == words.count - 1, colors: colors, font: font,
                         indent: size.width * 0.07)
                    .id(item.id)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: words.map(\.id))
        .frame(width: size.width, height: wallHeight)
        // The slow 3D drift. It follows the wall clock, so it keeps moving through pauses.
        .rotation3DEffect(.degrees(sin(0.35 * clock) * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .rotation3DEffect(.degrees(sin(0.22 * clock) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        .scaleEffect(1 + sin(0.17 * clock) * 0.035)
        .position(x: size.width / 2, y: size.height / 2)
    }

    struct WallItem {
        var word: Word
        var id: String          // stable across frames, so SwiftUI can animate it in and out
        var averageLength: Double
    }

    /// The last few words that have started in the current line. The line stays until
    /// shortly after its last word ends; after that the wall empties.
    private func startedWords() -> [WallItem] {
        let time = songTime
        var current: Int? = nil
        for (index, line) in lines.enumerated() where (line.words.first?.start ?? line.start) <= time {
            current = index
        }
        guard let current, let last = lines[current].words.last, time <= last.end + lineHold else { return [] }

        let line = lines[current]
        let average = line.words.reduce(0) { $0 + max($1.end - $1.start, 0.01) } / Double(line.words.count)
        var items: [WallItem] = []
        for (k, word) in line.words.enumerated() where word.start <= time {
            items.append(WallItem(word: word, id: "\(current)-\(k)", averageLength: average))
        }
        return Array(items.suffix(visibleWords))
    }

    /// Held words grow: the square root of (length / line average), kept between 0.75x and 1.55x.
    /// No word may be wider than 62% of the screen.
    private func fontSize(_ item: WallItem, wallHeight: CGFloat, width: CGFloat) -> CGFloat {
        let length = max(item.word.end - item.word.start, 0.01)
        let ratio = min(max(sqrt(length / item.averageLength), 0.75), 1.55)
        var size = wallHeight * 0.075 * ratio / 0.7  // 0.7 is roughly the cap height of SF Pro per point
        let measured = (item.word.text.lowercased() as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
        if measured > width * 0.62 {
            size *= width * 0.62 / measured
        }
        return size
    }
}

/// One word in the wall, with its fixed random tilt, indent and (sometimes) a band behind it.
struct WallWord: View {
    let text: String
    let id: String
    let fontSize: CGFloat
    let newest: Bool
    let colors: LyricColors
    let font: LyricFont
    let indent: CGFloat

    var body: some View {
        let seed = stableSeed(id)
        let banded = seeded(seed, 3) < 0.2
        let tilt = (seeded(seed, 1) * 2 - 1) * 4.5

        Text(text.lowercased())
            .font(font.font(size: fontSize))
            .foregroundStyle(banded ? readableOn(colors.highlight) : (newest ? colors.text : colors.secondary))
            .padding(.horizontal, banded ? fontSize * 0.14 : 0)
            .padding(.vertical, banded ? fontSize * 0.02 : 0)
            .background(banded ? colors.highlight : .clear)
            .opacity(newest ? 1 : 0.7)
            .shadow(color: .black.opacity(0.55), radius: 4)
            .rotationEffect(.degrees(tilt))
            .padding(.leading, indent * seeded(seed, 2))
    }
}

/// A repeatable number for a string id, to seed per-word randomness.
func stableSeed(_ text: String) -> Int {
    var hash = 5381
    for byte in text.utf8 {
        hash = (hash &* 33) &+ Int(byte)  // djb2
    }
    return hash
}

/// Black or white, whichever reads better on the given colour.
func readableOn(_ color: Color) -> Color {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
    let brightness = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    return brightness > 0.6 ? .black : .white
}
