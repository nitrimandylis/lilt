import SwiftUI

/// Codestyle: each lyric is typed out as a line of code, a.b.c(d); in bold monospace with
/// syntax colours. Letters pop in as they are sung, glowing briefly, behind a red cursor.
///
/// Studied from Verci's decompiled Flashbang scene (its menu calls it Codestyle), written fresh:
/// - a line is split into chunks of at most 3 words; each chunk is one line of "code";
/// - words are joined with dots; "I" words are keywords, "you/he/she" words are accents;
/// - some chunks become // comments, some wrap their last word in parentheses, line ends may get ";";
/// - each letter appears at its share of the word's sung time and springs from 142% to 100%;
/// - the cursor stays solid while singing and blinks at 1.1 Hz in between.
struct CodeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    let withIcons: Bool
    var settings = StyleSettings()

    var body: some View {
        TimelineView(.animation) { timeline in
            let painter = CodePainter(lines: model.lyrics?.lines ?? [],
                                      songTime: settings.songTime(player: player, model: model, at: timeline.date),
                                      clock: timeline.date.timeIntervalSinceReferenceDate, withIcons: withIcons)
            Canvas { context, size in painter.draw(context, size: size) }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

enum CodeRole {
    case identifier, keyword, accent, payload, punct, comment

    /// A fixed syntax theme, like an editor's, independent of the album colours.
    var color: Color {
        switch self {
        case .identifier: return Color(red: 0.55, green: 0.65, blue: 1.0)
        case .keyword: return Color(red: 1.0, green: 0.23, blue: 0.19)
        case .accent: return Color(red: 1.0, green: 0.65, blue: 0.32)
        case .payload: return .white
        case .punct: return Color(red: 0.55, green: 0.65, blue: 1.0).opacity(0.75)
        case .comment: return Color(red: 0.62, green: 0.65, blue: 0.70).opacity(0.85)
        }
    }
}

/// One character of a code line, with the moment it gets typed.
struct CodeGlyph {
    var character: String
    var role: CodeRole
    var revealAt: Double
}

struct CodeChunk {
    var glyphs: [CodeGlyph]
    var words: [Word]
    var start: Double       // when its first word starts
    var caption: String?    // a small "seen 2:14 am" under some line endings
    var seed: Int
}

/// Words that read as the singer: drawn as keywords.
let firstPersonWords: Set<String> = ["i", "im", "i'm", "ive", "i've", "id", "i'd", "ill", "i'll", "me", "my"]
/// Words about someone else: drawn in the accent colour.
let otherPersonWords: Set<String> = ["you", "youre", "you're", "your", "youve", "you've", "youll", "you'll", "u", "ur",
                                     "she", "shes", "she's", "he", "hes", "he's", "her", "him"]

/// Splits a line into chunks of at most 3 words, as evenly as possible.
func codeChunks(for line: LyricLine) -> [CodeChunk] {
    let words = line.words.filter { !$0.text.isEmpty }
    guard !words.isEmpty else { return [] }
    let count = (words.count + 2) / 3  // ceil(n / 3)
    var chunks: [CodeChunk] = []
    var next = 0
    for c in 0..<count {
        let size = (words.count - next) / (count - c)  // spread the remainder evenly
        let slice = Array(words[next..<(next + size)])
        next += size
        chunks.append(buildChunk(slice, isLastInLine: c == count - 1))
    }
    return chunks
}

/// How long a word's letters take to type: its sung length, kept between 0.01 and 0.45 s.
func typingSpan(_ word: Word) -> Double {
    return min(max(word.end - word.start, 0.01), 0.45)
}

private func buildChunk(_ words: [Word], isLastInLine: Bool) -> CodeChunk {
    let start = words[0].start
    let seed = Int(start * 1000)
    var glyphs: [CodeGlyph] = []

    func type(_ text: String, role: CodeRole, word: Word) {
        let letters = Array(text)
        let span = typingSpan(word)
        for (k, letter) in letters.enumerated() {
            // Letter k of n appears at its share of the word's time.
            let at = word.start + span * Double(k + 1) / Double(letters.count)
            glyphs.append(CodeGlyph(character: String(letter), role: role, revealAt: at))
        }
    }
    func mark(_ text: String, role: CodeRole, at time: Double) {
        for letter in text {
            glyphs.append(CodeGlyph(character: String(letter), role: role, revealAt: time))
        }
    }

    let lowered = words.map { $0.text.lowercased() }
    var caption: String? = nil

    if seeded(seed, 1) < 0.12 {
        // About 1 chunk in 8 becomes a comment.
        mark("// ", role: .comment, at: start)
        for (i, word) in words.enumerated() {
            if i > 0 { mark(" ", role: .comment, at: word.start) }
            type(lowered[i], role: .comment, word: word)
        }
    } else {
        let wrapLast = words.count > 1 && seeded(seed, 2) < 0.5
        for (i, word) in words.enumerated() {
            if i > 0 { mark(".", role: .punct, at: word.start) }
            let isLast = i == words.count - 1
            if isLast && wrapLast {
                mark("(", role: .punct, at: word.start)
                type(lowered[i], role: .payload, word: word)
                mark(")", role: .punct, at: word.start + typingSpan(word))
            } else {
                let bare = lowered[i].filter { $0.isLetter || $0 == "'" }
                let role: CodeRole = firstPersonWords.contains(bare) ? .keyword
                    : otherPersonWords.contains(bare) ? .accent : .identifier
                type(lowered[i], role: role, word: word)
            }
        }
        if isLastInLine && seeded(seed, 3) < 0.65, let last = words.last {
            mark(";", role: .punct, at: last.start + typingSpan(last))
        }
    }

    if isLastInLine && seeded(seed, 4) < 0.22 {
        let minute = 1 + Int(seeded(seed, 5) * 4)
        let second = Int(seeded(seed, 6) * 60)
        caption = String(format: "seen %d:%02d am", minute, second)
    }
    return CodeChunk(glyphs: glyphs, words: words, start: start, caption: caption, seed: seed)
}

struct CodePainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double
    var withIcons = false

    let cursorColor = Color(red: 1.0, green: 0.16, blue: 0.13)

    func draw(_ context: GraphicsContext, size: CGSize) {
        guard let (previous, current) = visibleChunks() else { return }

        // Size the text so the longer of the two rows fits 80% of the width.
        let longest = max(previous?.glyphs.count ?? 0, current.glyphs.count, 12)
        let fontSize = min(size.height * 0.06, size.width * 0.8 / (CGFloat(longest) * 0.6))
        let font = Font.system(size: fontSize, weight: .bold, design: .monospaced)
        let charWidth = context.resolve(Text("M").font(font)).measure(in: size).width

        var scene = context
        scene.addFilter(.shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 3))

        let rowGap = fontSize * 1.48  // a line height plus 0.48 of spacing
        let middle = size.height / 2
        if let previous {
            var dim = scene
            dim.opacity = 0.45
            drawRow(previous, context: dim, size: size, y: middle - rowGap / 2, font: font, fontSize: fontSize,
                    charWidth: charWidth, isCurrent: false)
        }
        drawRow(current, context: scene, size: size, y: previous == nil ? middle : middle + rowGap / 2, font: font,
                fontSize: fontSize, charWidth: charWidth, isCurrent: true)
    }

    /// The chunk being sung and the one before it (which may belong to the previous line).
    private func visibleChunks() -> (CodeChunk?, CodeChunk)? {
        var all: [CodeChunk] = []
        var currentIndex: Int? = nil
        for line in lines {
            guard let first = line.words.first, first.start <= songTime + 5 else { break }  // no need to chunk the future
            for chunk in codeChunks(for: line) {
                all.append(chunk)
                if chunk.start <= songTime { currentIndex = all.count - 1 }
            }
        }
        guard let currentIndex else { return nil }
        let previous = currentIndex > 0 ? all[currentIndex - 1] : nil
        return (previous, all[currentIndex])
    }

    private func drawRow(_ chunk: CodeChunk, context: GraphicsContext, size: CGSize, y: CGFloat, font: Font,
                         fontSize: CGFloat, charWidth: CGFloat, isCurrent: Bool) {
        // The row slams in from below and to one side over 0.24 s, then drifts slowly.
        let p = clamp((songTime - chunk.start) / 0.24)
        let settle = pow(1 - p, 3)
        let side: Double = seeded(chunk.seed, 7) < 0.5 ? -1 : 1
        let h = size.height * 0.5
        let dx = 0.46 * h * 0.35 * side * settle + 0.032 * h * sin(0.31 * clock) + 0.045 * h * (2 * seeded(chunk.seed, 8) - 1)
        let dy = 0.46 * h * settle + 0.032 * h * sin(0.31 * clock * 0.73 + 1.7)
        let tilt = 4 * side * settle + 2.6 * (2 * seeded(chunk.seed, 9) - 1) + 2.8 * sin(0.23 * clock)
        let pop = songTime < chunk.start ? 1.1 : 1 + 0.1 * exp(-(songTime - chunk.start) / 0.32)

        var row = context
        row.translateBy(x: size.width / 2 + dx, y: y + dy)
        row.rotate(by: .degrees(tilt))
        row.scaleBy(x: pop, y: pop)

        let width = CGFloat(chunk.glyphs.count) * charWidth
        var x = -width / 2
        if withIcons { drawIcon(for: chunk, context: row, x: x - fontSize * 0.3, fontSize: fontSize) }
        var cursorX = x
        var typing = false

        for glyph in chunk.glyphs {
            let age = songTime - glyph.revealAt
            if age < 0 {
                x += charWidth
                continue
            }
            // A damped spring: pops to 142% and settles; the glow starts wide and shrinks.
            let scale = 1 + 0.42 * exp(-age / 0.1) * cos(20 * age)
            let glow = fontSize * 0.32 * (1 + 1.4 * exp(-age / 0.14))
            var letter = row
            letter.addFilter(.shadow(color: glyph.role.color.opacity(0.35), radius: glow))
            letter.translateBy(x: x + charWidth / 2, y: 0)
            letter.scaleBy(x: scale, y: scale)
            letter.draw(context.resolve(Text(glyph.character).font(font).foregroundStyle(glyph.role.color)), at: .zero, anchor: .center)
            x += charWidth
            cursorX = x
            if age < 0.45 { typing = true }
        }

        guard isCurrent else { return }

        // Solid while letters are landing, otherwise a slow 1.1 Hz blink.
        let blinkOn = sin(2 * Double.pi * clock * 1.1) > 0
        let cursorOpacity = typing ? 1 : (blinkOn ? 1 : 0.12)
        let cursor = CGRect(x: cursorX + charWidth * 0.08, y: -fontSize * 0.54, width: charWidth * 0.55, height: fontSize * 1.08)
        row.fill(Path(roundedRect: cursor, cornerRadius: charWidth * 0.12), with: .color(cursorColor.opacity(cursorOpacity)))

        drawCaption(chunk, row: row, context: context, width: width, fontSize: fontSize)
    }

    /// Codestyle Visual: half the chunks get an icon before the code, from their newest word that
    /// has one. It springs in and untwists from -14 degrees, in the accent colour.
    private func drawIcon(for chunk: CodeChunk, context: GraphicsContext, x: CGFloat, fontSize: CGFloat) {
        guard seeded(chunk.seed, 10) < 0.5 else { return }
        let sung = chunk.words.filter { $0.start <= songTime }
        guard let word = sung.last(where: { WordIcons.shared.symbol(for: $0.text) != nil }),
              let symbol = WordIcons.shared.symbol(for: word.text) else { return }
        let age = songTime - word.start
        let spring = 1 - exp(-age / 0.1) * cos(14 * age)  // overshoots, then settles at 1
        var icon = context
        icon.translateBy(x: x - fontSize * 0.5, y: 0)
        icon.rotate(by: .degrees(-14 * exp(-age / 0.15)))
        icon.scaleBy(x: spring, y: spring)
        let image = Image(systemName: symbol)
        icon.draw(context.resolve(Text(image).font(.system(size: fontSize, weight: .bold)).foregroundStyle(CodeRole.accent.color)),
                  at: .zero, anchor: .center)
    }

    private func drawCaption(_ chunk: CodeChunk, row: GraphicsContext, context: GraphicsContext, width: CGFloat, fontSize: CGFloat) {
        if let caption = chunk.caption, let last = lines.last(where: { $0.words.first?.start ?? 0 <= songTime }),
           let lastWord = last.words.last, songTime >= lastWord.start {
            // The caption fades in to 80% over 0.3 s once the last word starts.
            var note = row
            note.opacity = 0.8 * clamp((songTime - lastWord.start) / 0.3)
            let text = Text(caption).font(.system(size: fontSize * 0.36, weight: .bold, design: .monospaced))
                .foregroundStyle(CodeRole.comment.color)
            note.draw(context.resolve(text), at: CGPoint(x: width / 2, y: fontSize * 0.9), anchor: .topTrailing)
        }
    }
}
