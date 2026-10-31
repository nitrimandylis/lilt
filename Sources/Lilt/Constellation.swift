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

/// Holds one frame's worth of state and draws it. Plain struct, so nothing here touches UI state.
///
/// Timing model (studied from Verci's constellation, written fresh here):
/// - a word reveals over its own sung length with an ease-out cubic, so long notes bloom slowly;
/// - when a word lands it gets a damped "kick": a quick overshoot in size and tilt that settles in ~0.5 s;
/// - the word being sung pulses a ring that grows and fades, about once per second;
/// - words sit on a spiral around a seeded anchor, so each line forms its own shape.
struct ConstellationPainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double  // wall-clock seconds, for twinkling that keeps going when paused
    let accent: Color
    let caption: String

    let minimumWordLength = 0.08  // seconds; stops tiny words from popping in a single frame
    let activeTail = 0.2          // a word stays "current" this long after it ends
    let fadeSeconds = 1.2         // how long a finished line takes to fade

    func draw(_ context: GraphicsContext, size: CGSize) {
        // Dim the lock screen wallpaper a little so the words stay readable.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
        drawStarfield(context, size: size)

        if let current = currentLineIndex() {
            if current > 0 {
                // The previous line fades out and drifts up as the new one starts.
                let since = songTime - lines[current].start
                drawLine(current - 1, context: context, size: size, fade: 1 - clamp(since / fadeSeconds))
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

    // MARK: Timing

    /// 0 before the word starts, easing out to 1 by the time it ends.
    private func reveal(_ word: Word) -> Double {
        let length = max(word.end - word.start, minimumWordLength)
        let linear = clamp((songTime - word.start) / length)
        return 1 - pow(1 - linear, 3)  // ease-out cubic: fast start, gentle finish
    }

    /// A spring that fires when the word lands: starts at -1, swings, and dies out.
    /// exp(-t / 0.16) is the decay, cos(15t + pi) the wobble (about 2.4 swings a second).
    private func kick(_ word: Word) -> Double {
        let t = songTime - word.start
        if t < 0 { return 0 }
        return exp(-t / 0.16) * cos(15 * t + .pi)
    }

    private func isCurrent(_ word: Word) -> Bool {
        return songTime >= word.start && songTime < word.end + activeTail
    }

    // MARK: Layout

    private struct PlacedWord {
        var word: Word
        var center: CGPoint
    }

    /// Walks out from a seeded anchor along a golden-angle spiral, taking the first
    /// spot where the word's box does not overlap an earlier word and stays on screen.
    private func layout(_ index: Int, context: GraphicsContext, size: CGSize, fontSize: CGFloat) -> [PlacedWord] {
        let words = lines[index].words
        let font = Font.system(size: fontSize, weight: .semibold, design: .rounded)
        let boxes = words.map { context.resolve(Text($0.text.lowercased()).font(font)).measure(in: size) }

        // Keep 14% clear on every side.
        let margin = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.14, dy: size.height * 0.14)
        let anchor = CGPoint(x: margin.minX + margin.width * (0.25 + 0.5 * seeded(index, 1)),
                             y: margin.minY + margin.height * (0.25 + 0.5 * seeded(index, 2)))
        let startAngle = seeded(index, 3) * 2 * Double.pi
        let step = size.height * 0.09 * (0.8 + 0.55 * seeded(index, 4))
        let goldenAngle = 2.399963  // radians; spreads points evenly without lining them up

        var placed: [PlacedWord] = []
        var taken: [CGRect] = []
        for k in words.indices {
            var spot = anchor
            for attempt in 0..<60 {
                let n = Double(placed.count + attempt)
                let angle = startAngle + n * goldenAngle + (seeded(index * 100 + k, attempt) - 0.5) * 0.6
                let radius = step * sqrt(n + 1)
                let candidate = CGPoint(x: anchor.x + cos(angle) * radius, y: anchor.y + sin(angle) * radius * 0.6)
                let box = CGRect(x: candidate.x - boxes[k].width / 2 - 14, y: candidate.y - boxes[k].height / 2 - 18,
                                 width: boxes[k].width + 28, height: boxes[k].height + 36)
                let overlaps = taken.contains { $0.intersects(box) }
                if !overlaps && margin.contains(candidate) {
                    spot = candidate
                    break
                }
                // ponytail: if 60 tries all fail the word lands on the anchor; fine for normal line lengths.
            }
            taken.append(CGRect(x: spot.x - boxes[k].width / 2 - 14, y: spot.y - boxes[k].height / 2 - 18,
                                width: boxes[k].width + 28, height: boxes[k].height + 36))
            placed.append(PlacedWord(word: words[k], center: spot))
        }
        return placed
    }

    // MARK: Drawing

    private func drawLine(_ index: Int, context: GraphicsContext, size: CGSize, fade: Double) {
        guard fade > 0 else { return }
        var layer = context
        layer.opacity = fade
        layer.translateBy(x: 0, y: -(1 - fade) * 50)

        let fontSize = size.width * 0.026
        let placed = layout(index, context: context, size: size, fontSize: fontSize)

        // Links between consecutive words, growing toward each word as it lights.
        for k in placed.indices.dropFirst() {
            let progress = reveal(placed[k].word)
            if progress <= 0.01 { continue }
            let from = placed[k - 1].center
            let to = placed[k].center
            let tip = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
            var link = Path()
            link.move(to: from)
            link.addLine(to: tip)
            layer.stroke(link, with: .color(accent.opacity(0.5 * progress)), lineWidth: 1.4)
        }

        for item in placed {
            let progress = reveal(item.word)
            if progress <= 0 { continue }
            let current = isCurrent(item.word)
            let spring = kick(item.word)

            drawStar(at: item.center, progress: progress, spring: spring, context: layer)
            if current {
                drawRing(at: item.center, word: item.word, context: layer)
            }

            // Text sits under its star, bounces with the kick, and shimmers very slightly.
            let shimmer = 1 + 0.04 * sin(seeded(Int(item.word.start * 1000), 7) * 6.28 + clock * 2.8)
            let scale = (current ? 1.0 : 0.72) * (1 + 0.35 * spring) * shimmer
            let font = Font.system(size: fontSize, weight: .semibold, design: .rounded)
            let color = current ? accent : Color.white
            let text = context.resolve(Text(item.word.text.lowercased()).font(font).foregroundStyle(color))

            var textLayer = layer
            textLayer.opacity = fade * progress * (current ? 1 : 0.55)
            textLayer.translateBy(x: item.center.x, y: item.center.y + fontSize * 0.95)
            textLayer.rotate(by: .degrees(8 * spring))
            textLayer.scaleBy(x: scale, y: scale)
            textLayer.draw(text, at: .zero, anchor: .center)
        }
    }

    /// A glowing dot with a four-point flare; the flare overshoots with the kick then settles.
    private func drawStar(at point: CGPoint, progress: Double, spring: Double, context: GraphicsContext) {
        let glow = 12 * progress * (1 + 0.5 * abs(spring))
        let glowRect = CGRect(x: point.x - glow, y: point.y - glow, width: glow * 2, height: glow * 2)
        context.fill(Path(ellipseIn: glowRect), with: .radialGradient(
            Gradient(colors: [accent.opacity(0.5), .clear]), center: point, startRadius: 0, endRadius: glow))

        let core = 2.4 * progress
        context.fill(Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
                     with: .color(.white))

        let arm = 5 + 16 * abs(spring)
        var flare = Path()
        flare.move(to: CGPoint(x: point.x - arm, y: point.y))
        flare.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        flare.move(to: CGPoint(x: point.x, y: point.y - arm))
        flare.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(flare, with: .color(.white.opacity(0.6 * progress)), lineWidth: 0.8)
    }

    /// While a word is being sung, a ring grows to five times its size and fades, 1.2 times a second.
    private func drawRing(at point: CGPoint, word: Word, context: GraphicsContext) {
        let elapsed = max(songTime - word.start, 0)
        let phase = (elapsed * 1.2).truncatingRemainder(dividingBy: 1)
        let radius = 6 * (1 + 4 * phase)
        let ring = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: ring), with: .color(accent.opacity((1 - phase) * 0.8)), lineWidth: 2)
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
