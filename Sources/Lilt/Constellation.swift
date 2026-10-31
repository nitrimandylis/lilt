import SwiftUI

/// The constellation style: each sung word lands as a four-point star with its word beside it,
/// a line traces from the previous star, and finished lines drift up and fade.
///
/// Timing and look studied from Verci's decompiled Constellation scene, written fresh here:
/// - a word's star grows over its own sung length with an ease-out cubic;
/// - when a word lands it gets a damped "kick" (size, tilt, and a tiny shake of the whole scene);
/// - the word being sung pulses a ring that grows and fades about once a second;
/// - no background, no glow: the scene floats over the wallpaper with one soft drop shadow.
struct ConstellationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    @AppStorage("textColor") private var textHex = Theme.defaultText
    @AppStorage("highlightColor") private var highlightHex = Theme.defaultHighlight
    @AppStorage("secondaryColor") private var secondaryHex = Theme.defaultSecondary
    @AppStorage("autoSyncColors") private var autoSync = true
    @AppStorage("lyricFont") private var fontChoice = LyricFont.sfPro.rawValue
    @AppStorage("lyricsDelay") private var delay = 0.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                makePainter(at: timeline.date).draw(context, size: size)
            }
        }
        .background(Color.black)  // its own dark stage, not a see-through layer over apps
        .ignoresSafeArea()
    }

    private func makePainter(at date: Date) -> ConstellationPainter {
        var text = colorFromHex(textHex)
        var highlight = colorFromHex(highlightHex)
        var secondary = colorFromHex(secondaryHex)
        if autoSync, let palette = model.palette {
            // Auto Sync: the album art picks all three colours.
            text = palette.text
            highlight = palette.highlight
            secondary = palette.secondary
        }
        return ConstellationPainter(
            lines: model.lyrics?.lines ?? [],
            // Positive delay holds the lyrics back to match what you actually hear.
            songTime: player.position(at: date) - delay - model.outputDelay,
            clock: date.timeIntervalSinceReferenceDate,
            textColor: text,
            highlight: highlight,
            secondary: secondary,
            font: LyricFont(rawValue: fontChoice) ?? .sfPro
        )
    }
}

/// Holds one frame's worth of state and draws it. Plain struct, so nothing here touches UI state.
struct ConstellationPainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double  // wall-clock seconds, for twinkling that keeps going when paused
    let textColor: Color
    let highlight: Color
    let secondary: Color
    let font: LyricFont

    let minimumWordLength = 0.08  // seconds; floor for word length when judging held notes
    let revealMinimum = 0.45      // seconds; even the quickest word takes this long to bloom
    let kickAmount = 0.1          // how far a landing word overshoots in size (10%)
    let activeTail = 0.2          // a word stays "current" this long after it ends
    let fadeSeconds = 1.2         // how long a finished line takes to fade

    func draw(_ context: GraphicsContext, size: CGSize) {
        var scene = context
        // One soft shadow under everything keeps white text readable on any wallpaper.
        scene.addFilter(.shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2))

        drawDust(scene, size: size)

        guard let current = currentLineIndex() else { return }

        if current > 0 {
            // The previous line fades out and drifts up as the new one starts.
            let since = songTime - lines[current].start
            drawLine(current - 1, context: scene, size: size, fade: 1 - clamp(since / fadeSeconds))
        }
        // A line left alone through a long instrumental also fades away.
        let afterEnd = songTime - (lines[current].end + 3)
        drawLine(current, context: scene, size: size, fade: 1 - clamp(afterEnd / 1.5))
    }

    /// The last line that has started, or nil before the first one.
    private func currentLineIndex() -> Int? {
        var found: Int? = nil
        for (index, line) in lines.enumerated() where line.start <= songTime + 0.05 {
            found = index
        }
        return found
    }

    /// 26 faint motes in the text colour, each breathing slowly.
    private func drawDust(_ context: GraphicsContext, size: CGSize) {
        for i in 0..<26 {
            let x = seeded(500 + i, 1) * size.width
            let y = seeded(500 + i, 2) * size.height
            let radius = 1.0 + 1.2 * seeded(500 + i, 3)
            let alpha = (0.6 + 0.4 * sin(0.8 * clock + seeded(500 + i, 4) * 6.28)) * 0.14
            let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(textColor.opacity(alpha)))
        }
    }

    // MARK: Timing

    private func length(_ word: Word) -> Double {
        return max(word.end - word.start, minimumWordLength)
    }

    /// 0 before the word starts, easing out to 1 over the word's length (at least `revealMinimum`).
    private func reveal(_ word: Word) -> Double {
        let linear = clamp((songTime - word.start) / max(length(word), revealMinimum))
        return 1 - pow(1 - linear, 3)  // ease-out cubic: fast start, gentle finish
    }

    /// A soft spring when the word lands: starts at -1, one slow swing, settles in about a second.
    /// exp(-t / 0.3) is the decay, cos(8t + pi) the swing.
    private func kick(_ word: Word) -> Double {
        let t = songTime - word.start
        if t < 0 { return 0 }
        return exp(-t / 0.3) * cos(8 * t + .pi)
    }

    private func isCurrent(_ word: Word) -> Bool {
        return songTime >= word.start && songTime < word.end + activeTail
    }

    /// A held note: at least 1.6 times as long as the line's average word.
    // ponytail: Verci compares against a value we could not identify; the line average is our stand-in.
    private func isLong(_ word: Word, in line: LyricLine) -> Bool {
        let average = line.words.reduce(0) { $0 + length($1) } / Double(max(line.words.count, 1))
        return length(word) >= 1.6 * average && line.words.count > 1
    }

    // MARK: Layout

    private enum LabelSide: CaseIterable {
        case below, above, right, left
    }

    private struct PlacedWord {
        var word: Word
        var center: CGPoint
        var textSize: CGSize  // measured at the active size
        var side = LabelSide.below
        var label = CGRect.zero  // where the text goes, beside its star
    }

    /// Grows the line as a path, word to word, starting from an anchor that keeps clear of the
    /// previous line and heading away from it. Each step tries seeded directions around the current
    /// heading and takes the first spot that stays on screen, does not overlap a word, and whose
    /// link neither crosses an earlier link nor runs through another word.
    private func layout(_ index: Int, context: GraphicsContext, size: CGSize, baseFont: CGFloat) -> [PlacedWord] {
        let words = lines[index].words
        guard !words.isEmpty else { return [] }
        // Measure at the active size, the biggest a word gets, so a lit word never collides.
        let boxes = words.map { word in
            context.resolve(Text(word.text.lowercased()).font(font.font(size: baseFont * 1.8))).measure(in: size)
        }

        // Keep 14% clear on every side.
        let margin = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.14, dy: size.height * 0.14)
        let (start, previous) = anchors(upTo: index, in: margin)

        // Point away from where the last line was, give or take 45 degrees.
        var heading = seeded(index, 3) * 2 * Double.pi
        if let previous {
            heading = atan2(start.y - previous.y, start.x - previous.x) + (seeded(index, 5) - 0.5) * 1.6
        }

        var placed = [PlacedWord(word: words[0], center: start, textSize: boxes[0])]
        var taken = [footprint(start, boxes[0])]
        var links: [(CGPoint, CGPoint)] = []

        for k in words.indices.dropFirst() {
            let from = placed[k - 1].center
            let distance = (boxes[k - 1].width + boxes[k].width) * 0.3 + size.height * (0.07 + 0.05 * seeded(index * 100 + k, 1))
            var chosen: CGPoint? = nil

            // First 30 tries obey every rule; the next 30 only avoid overlapping words.
            for attempt in 0..<60 {
                let strict = attempt < 30
                let spread = 1.2 + Double(attempt % 30) * 0.15  // widen the search as tries fail
                let angle = heading + (seeded(index * 100 + k, 10 + attempt) - 0.5) * spread
                let candidate = CGPoint(x: from.x + cos(angle) * distance, y: from.y + sin(angle) * distance * 0.75)

                let box = footprint(candidate, boxes[k])
                guard margin.contains(candidate), !taken.contains(where: { $0.intersects(box) }) else { continue }
                if strict {
                    // Skip the last link: it shares an end with the new one, so it always "touches".
                    let crosses = links.dropLast().contains { segmentsCross(from, candidate, $0.0, $0.1) }
                    let throughWord = taken.dropLast().contains { segment(from, candidate, hits: $0) }
                    if crosses || throughWord { continue }
                }
                chosen = candidate
                heading = angle  // keep walking roughly the same way, so the line reads as a path
                break
            }

            // ponytail: a very long line can run out of room; the word then sits in the nearest on-screen spot.
            let spot = chosen ?? CGPoint(x: min(max(from.x + cos(heading) * distance, margin.minX), margin.maxX),
                                         y: min(max(from.y + sin(heading) * distance, margin.minY), margin.maxY))
            links.append((from, spot))
            taken.append(footprint(spot, boxes[k]))
            placed.append(PlacedWord(word: words[k], center: spot, textSize: boxes[k]))
        }

        // Like a star chart: put each label on the first side of its star that is free of
        // links, other labels and other stars. Below is preferred because it reads best.
        let screen = CGRect(origin: .zero, size: size)
        var labels: [CGRect] = []
        for k in placed.indices {
            let gap: CGFloat = isLong(words[k], in: lines[index]) ? 34 : 22  // clear the star at its biggest, more for held notes
            var chosenSide = LabelSide.below
            var chosenRect = labelArea(placed[k].center, boxes[k], side: .below, gap: gap)
            for side in LabelSide.allCases {
                let rect = labelArea(placed[k].center, boxes[k], side: side, gap: gap)
                let hitsLink = links.contains { segment($0.0, $0.1, hits: rect) }
                let hitsLabel = labels.contains { $0.intersects(rect) }
                let hitsStar = placed.indices.contains { $0 != k && rect.insetBy(dx: -8, dy: -8).contains(placed[$0].center) }
                if !hitsLink && !hitsLabel && !hitsStar && screen.contains(rect) {
                    chosenSide = side
                    chosenRect = rect
                    break
                }
            }
            placed[k].side = chosenSide
            placed[k].label = chosenRect
            labels.append(chosenRect)
        }
        return placed
    }

    /// The rectangle a label takes on one side of its star.
    private func labelArea(_ star: CGPoint, _ text: CGSize, side: LabelSide, gap: CGFloat) -> CGRect {
        switch side {
        case .below: return CGRect(x: star.x - text.width / 2, y: star.y + gap, width: text.width, height: text.height)
        case .above: return CGRect(x: star.x - text.width / 2, y: star.y - gap - text.height, width: text.width, height: text.height)
        case .right: return CGRect(x: star.x + gap, y: star.y - text.height / 2, width: text.width, height: text.height)
        case .left: return CGRect(x: star.x - gap - text.width, y: star.y - text.height / 2, width: text.width, height: text.height)
        }
    }

    /// Start points for lines 0...index, each chosen to sit well away from the one before.
    /// Returns this line's anchor and the previous line's (nil for the first line).
    private func anchors(upTo index: Int, in margin: CGRect) -> (CGPoint, CGPoint?) {
        var previous: CGPoint? = nil
        var current = CGPoint(x: margin.midX, y: margin.midY)
        for line in 0...index {
            var best = current
            var bestDistance = -1.0
            for candidate in 0..<8 {
                let point = CGPoint(x: margin.minX + margin.width * (0.15 + 0.7 * seeded(line, 20 + candidate)),
                                    y: margin.minY + margin.height * (0.15 + 0.7 * seeded(line, 40 + candidate)))
                guard let last = (line == 0 ? nil : current) else {
                    best = point
                    break
                }
                let distance = hypot(point.x - last.x, point.y - last.y)
                if distance >= margin.width * 0.35 {
                    best = point  // far enough; taking the first keeps the placement varied
                    break
                }
                if distance > bestDistance {
                    best = point
                    bestDistance = distance
                }
            }
            if line > 0 { previous = current }
            current = best
        }
        return (current, previous)
    }

    /// The area a word claims: its star above, its text below, plus breathing room.
    private func footprint(_ star: CGPoint, _ text: CGSize) -> CGRect {
        return CGRect(x: star.x - text.width / 2 - 16, y: star.y - 24,
                      width: text.width + 32, height: text.height + 48)
    }

    // MARK: Drawing

    private func drawLine(_ index: Int, context: GraphicsContext, size: CGSize, fade: Double) {
        guard fade > 0 else { return }
        var layer = context
        layer.opacity = fade
        layer.translateBy(x: 0, y: -(1 - fade) * 50)

        let line = lines[index]
        let baseFont = size.width * 0.72 * 0.032  // 3.2% of the usable width
        let placed = layout(index, context: context, size: size, baseFont: baseFont)

        // Links between consecutive stars, growing toward each new star as it lights.
        for k in placed.indices.dropFirst() {
            let progress = reveal(placed[k].word)
            if progress <= 0.01 { continue }
            let from = placed[k - 1].center
            let to = placed[k].center
            let tip = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
            var link = Path()
            link.move(to: from)
            link.addLine(to: tip)
            layer.stroke(link, with: .color(highlight.opacity(0.5 * progress)), lineWidth: 1.4)
        }

        for item in placed {
            let progress = reveal(item.word)
            if progress <= 0 { continue }
            let current = isCurrent(item.word)
            let long = isLong(item.word, in: line)
            let spring = kick(item.word)
            let age = songTime - item.word.start

            // Star size: grows in, overshoots with the kick, twinkles 8% at 1.4 Hz.
            let twinkle = 1 + 0.08 * sin(2 * Double.pi * 1.4 * clock + seeded(Int(item.word.start * 1000), 7) * 6.28)
            var radius = progress * (1 + kickAmount * spring) * (current ? 13.5 : 9) * twinkle
            if long { radius *= 1.8 }

            var starLayer = layer
            starLayer.opacity = fade * (current ? 1 : 0.55)
            starLayer.fill(starPath(center: item.center, radius: radius), with: .color(current ? highlight : textColor))

            if current {
                // A ring grows to five times the star and fades, 1.2 times a second.
                let phase = (max(age, 0) * 1.2).truncatingRemainder(dividingBy: 1)
                let ringRadius = (1 + 4 * phase) * radius / 2
                let ring = CGRect(x: item.center.x - ringRadius, y: item.center.y - ringRadius,
                                  width: ringRadius * 2, height: ringRadius * 2)
                layer.stroke(Path(ellipseIn: ring), with: .color(highlight.opacity((1 - phase) * 0.8)), lineWidth: 2)
            }

            // Text fades in over 0.5 s while drifting up into place, with a slight tilt from the kick.
            var fontSize = baseFont * (current ? 1.8 : 1)
            if long { fontSize *= 2.4 / 1.8 }  // ponytail: tamed from Verci's x2.4 so long words fit our layout boxes
            let color = current ? textColor : secondary
            let text = context.resolve(Text(item.word.text.lowercased()).font(font.font(size: fontSize)).foregroundStyle(color))

            let fadeIn = smoothstep(age / 0.5)
            let scale = 1 + 0.06 * exp(-age / 0.3)
            var textLayer = layer
            textLayer.opacity = fade * fadeIn * (current ? 1 : 0.55)
            let settle = (1 - fadeIn) * 10  // starts 10 pt low
            // Pin the text to the edge of its label area that faces the star.
            let rect = item.label
            var pin = CGPoint(x: rect.midX, y: rect.minY)
            var anchor = UnitPoint.top
            switch item.side {
            case .below: pin = CGPoint(x: rect.midX, y: rect.minY); anchor = .top
            case .above: pin = CGPoint(x: rect.midX, y: rect.maxY); anchor = .bottom
            case .right: pin = CGPoint(x: rect.minX, y: rect.midY); anchor = .leading
            case .left: pin = CGPoint(x: rect.maxX, y: rect.midY); anchor = .trailing
            }
            textLayer.translateBy(x: pin.x, y: pin.y + settle)
            textLayer.rotate(by: .degrees(3 * spring))
            textLayer.scaleBy(x: scale, y: scale)
            textLayer.draw(text, at: .zero, anchor: anchor)
        }
    }

    /// A four-point star: tips on the axes, inner corners at 34% of the radius on the diagonals.
    private func starPath(center: CGPoint, radius: Double) -> Path {
        let inner = 0.34 * radius
        var path = Path()
        path.move(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + inner, y: center.y + inner))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - inner, y: center.y + inner))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - inner, y: center.y - inner))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + inner, y: center.y - inner))
        path.closeSubpath()
        return path
    }
}

/// True when segment a1-a2 properly crosses segment b1-b2.
func segmentsCross(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint) -> Bool {
    // Which side of a line a point is on: the sign of a cross product.
    func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
        return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
    }
    let d1 = side(b1, b2, a1)
    let d2 = side(b1, b2, a2)
    let d3 = side(a1, a2, b1)
    let d4 = side(a1, a2, b2)
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

/// True when segment p1-p2 enters the rectangle.
func segment(_ p1: CGPoint, _ p2: CGPoint, hits rect: CGRect) -> Bool {
    if rect.contains(p1) || rect.contains(p2) { return true }
    let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    for edge in 0..<4 where segmentsCross(p1, p2, corners[edge], corners[(edge + 1) % 4]) {
        return true
    }
    return false
}

func clamp(_ value: Double) -> Double {
    return min(max(value, 0), 1)
}

/// Eases 0...1 in and out (slow, fast, slow), clamping outside that range.
func smoothstep(_ value: Double) -> Double {
    let x = clamp(value)
    return x * x * (3 - 2 * x)
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
