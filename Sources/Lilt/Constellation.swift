import SwiftUI

/// The constellation style: each sung word lights up as a star with its word beside it,
/// a line traces from the previous star, and finished lines drift up and fade.
struct ConstellationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor

    var body: some View {
        TimelineView(.animation) { timeline in
            let painter = ConstellationPainter(
                lines: model.lyrics?.lines ?? [],
                songTime: player.position(at: timeline.date),
                clock: timeline.date.timeIntervalSinceReferenceDate,
                accent: albumAccent(hex: player.track?.accentHex),
                caption: captionText()
            )
            Canvas { context, size in
                painter.draw(context, size: size)
            }
        }
        .ignoresSafeArea()
    }

    private func captionText() -> String {
        guard let track = player.track else { return "" }
        return "\(track.title) — \(track.artist)"
    }
}

/// Holds one frame's worth of state and draws it. Plain struct, so nothing here touches the UI thread state.
struct ConstellationPainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double  // wall-clock seconds, for twinkling that keeps going when paused
    let accent: Color
    let caption: String

    let font = Font.system(size: 34, weight: .medium, design: .rounded)
    let revealSeconds = 0.35   // how long a word takes to light up
    let fadeSeconds = 1.2      // how long a finished line takes to fade

    func draw(_ context: GraphicsContext, size: CGSize) {
        // Dim the lock screen wallpaper a little so the words stay readable.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
        drawStarfield(context, size: size)

        if let current = currentLineIndex() {
            if current > 0 {
                // The previous line fades out and drifts up as the new one starts.
                let since = songTime - lines[current].start
                let fade = 1 - clamp(since / fadeSeconds)
                drawLine(current - 1, context: context, size: size, fade: fade)
            }
            // A line left alone through a long instrumental also fades away.
            let afterEnd = songTime - (lines[current].end + 3)
            drawLine(current, context: context, size: size, fade: 1 - clamp(afterEnd / 1.5))
        }

        let resolved = context.resolve(Text(caption).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.55)))
        context.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height - 60), anchor: .center)
    }

    /// The last line that has started, or nil before the first one.
    private func currentLineIndex() -> Int? {
        var found: Int? = nil
        for (index, line) in lines.enumerated() where line.start <= songTime + 0.05 {
            found = index
        }
        return found
    }

    private func drawStarfield(_ context: GraphicsContext, size: CGSize) {
        for i in 0..<160 {
            let x = seeded(9000 + i, 1) * size.width
            let y = seeded(9000 + i, 2) * size.height
            let radius = 0.6 + seeded(9000 + i, 3) * 1.2
            let speed = 0.5 + seeded(9000 + i, 4) * 1.5
            let phase = seeded(9000 + i, 5) * 6.28
            let alpha = 0.12 + 0.25 * (0.5 + 0.5 * sin(clock * speed + phase))
            let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(alpha)))
        }
    }

    private struct PlacedWord {
        var word: Word
        var text: GraphicsContext.ResolvedText
        var center: CGPoint  // where the word's text sits
        var star: CGPoint    // where its star sits, just above the text
    }

    /// Places a line's words in rows around a spot picked from the line number,
    /// with a little vertical jitter so the stars form a shape rather than a ruler.
    private func layout(_ index: Int, context: GraphicsContext, size: CGSize) -> [PlacedWord] {
        let words = lines[index].words
        let texts = words.map { context.resolve(Text($0.text).font(font).foregroundStyle(.white)) }
        let widths = texts.map { $0.measure(in: size).width }

        // Break into rows no wider than 62% of the screen.
        let gap: CGFloat = 26
        let maxRowWidth = size.width * 0.62
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for k in words.indices {
            if rowWidth + widths[k] > maxRowWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(k)
            rowWidth += widths[k] + gap
        }

        let rowHeight: CGFloat = 130
        let centerX = size.width * (0.35 + 0.3 * seeded(index, 1))
        let centerY = size.height * (0.32 + 0.26 * seeded(index, 2))
        let top = centerY - CGFloat(rows.count) * rowHeight / 2

        var placed: [PlacedWord] = []
        for (r, row) in rows.enumerated() {
            let width = row.reduce(0) { $0 + widths[$1] } + gap * CGFloat(row.count - 1)
            var x = centerX - width / 2
            let y = top + CGFloat(r) * rowHeight + rowHeight / 2
            for k in row {
                let jitter = (seeded(index, 10 + k) - 0.5) * 70
                let center = CGPoint(x: x + widths[k] / 2, y: y + jitter)
                let starOffset = (seeded(index, 50 + k) - 0.5) * widths[k] * 0.6
                let star = CGPoint(x: center.x + starOffset, y: center.y - 34 - seeded(index, 80 + k) * 40)
                placed.append(PlacedWord(word: words[k], text: texts[k], center: center, star: star))
                x += widths[k] + gap
            }
        }
        return placed
    }

    private func drawLine(_ index: Int, context: GraphicsContext, size: CGSize, fade: Double) {
        guard fade > 0 else { return }
        var layer = context
        layer.opacity = fade
        layer.translateBy(x: 0, y: -(1 - fade) * 50)

        let placed = layout(index, context: context, size: size)

        // Links between stars grow toward each new star as its word lights.
        for k in placed.indices.dropFirst() {
            let progress = reveal(placed[k].word)
            if progress <= 0 { continue }
            let from = placed[k - 1].star
            let to = placed[k].star
            let tip = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
            var link = Path()
            link.move(to: from)
            link.addLine(to: tip)
            layer.stroke(link, with: .color(accent.opacity(0.45)), lineWidth: 1)
        }

        for item in placed {
            let progress = reveal(item.word)
            if progress <= 0 { continue }
            let isCurrent = songTime >= item.word.start && songTime < item.word.end
            drawStar(at: item.star, progress: progress, bright: isCurrent, context: layer)

            var textLayer = layer
            textLayer.opacity = fade * progress * (isCurrent ? 1 : 0.7)
            let rise = (1 - progress) * 10
            let text = isCurrent
                ? context.resolve(Text(item.word.text).font(font).foregroundStyle(accent))
                : item.text
            textLayer.draw(text, at: CGPoint(x: item.center.x, y: item.center.y + rise), anchor: .center)
        }
    }

    /// A glowing dot, with a four-point flare that shrinks as the word finishes lighting.
    private func drawStar(at point: CGPoint, progress: Double, bright: Bool, context: GraphicsContext) {
        let glow = 10 * (1 + (1 - progress) * 1.5)
        let glowRect = CGRect(x: point.x - glow, y: point.y - glow, width: glow * 2, height: glow * 2)
        context.fill(Path(ellipseIn: glowRect), with: .radialGradient(
            Gradient(colors: [accent.opacity(bright ? 0.6 : 0.3), .clear]),
            center: point, startRadius: 0, endRadius: glow))

        let core: CGFloat = bright ? 3 : 2.2
        context.fill(Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
                     with: .color(.white))

        if bright || progress < 1 {
            let arm = 6 + 14 * (1 - progress)
            var flare = Path()
            flare.move(to: CGPoint(x: point.x - arm, y: point.y))
            flare.addLine(to: CGPoint(x: point.x + arm, y: point.y))
            flare.move(to: CGPoint(x: point.x, y: point.y - arm))
            flare.addLine(to: CGPoint(x: point.x, y: point.y + arm))
            context.stroke(flare, with: .color(.white.opacity(0.7)), lineWidth: 0.8)
        }
    }

    /// 0 before the word is sung, rising to 1 over `revealSeconds`.
    private func reveal(_ word: Word) -> Double {
        return clamp((songTime - word.start) / revealSeconds)
    }
}

func clamp(_ value: Double) -> Double {
    return min(max(value, 0), 1)
}

/// A repeatable 0..<1 number for a pair of integers, so a line keeps the same shape every frame.
func seeded(_ a: Int, _ b: Int) -> Double {
    var x = UInt64(bitPattern: Int64(a &* 92821 &+ b &* 68917 &+ 1))
    x ^= x >> 33
    x = x &* 0xff51afd7ed558ccd
    x ^= x >> 33
    x = x &* 0xc4ceb9fe1a85ec53
    x ^= x >> 33
    return Double(x % 1_000_000) / 1_000_000
}

/// Album colour from Cider ("fa233b"), lifted toward white when it is too dark to read on a lock screen.
func albumAccent(hex: String?) -> Color {
    guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else {
        return Color(red: 0.75, green: 0.85, blue: 1.0)  // pale starlight blue
    }
    var red = Double((value >> 16) & 0xff) / 255
    var green = Double((value >> 8) & 0xff) / 255
    var blue = Double(value & 0xff) / 255
    let brightness = 0.299 * red + 0.587 * green + 0.114 * blue
    if brightness < 0.55 {
        let lift = 0.55 - brightness + 0.15
        red += (1 - red) * lift
        green += (1 - green) * lift
        blue += (1 - blue) * lift
    }
    return Color(red: red, green: green, blue: blue)
}
