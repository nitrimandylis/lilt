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
    @State private var layouts = LayoutCache()

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
            font: LyricFont(rawValue: fontChoice) ?? .sfPro,
            layouts: layouts
        )
    }
}

enum LabelSide: CaseIterable {
    case below, above, right, left
}

struct PlacedWord {
    var word: Word
    var center: CGPoint
    var label: CGRect    // where the text goes, beside its star, at the biggest size it is drawn
    var side: LabelSide
}

/// Remembers each line's layout, so a line keeps its shape from frame to frame and the next
/// line can steer around it. Cleared whenever the lyrics, window size or font change.
final class LayoutCache {
    var key = ""
    var lines: [Int: [PlacedWord]] = [:]
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
    let layouts: LayoutCache

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

    private let activeScale: CGFloat = 1.5  // the word being sung is drawn this much bigger
    private let longScale: CGFloat = 1.2    // held notes get this much more on top

    private func baseFontSize(_ size: CGSize) -> CGFloat {
        return size.width * 0.72 * 0.026
    }

    /// The layout for one line, worked out once and cached. Lines are laid out in order,
    /// because each one steers around the line before it.
    private func placedWords(_ index: Int, context: GraphicsContext, size: CGSize) -> [PlacedWord] {
        let first = lines.first?.start ?? 0
        let last = lines.last?.end ?? 0
        let key = "\(lines.count)|\(first)|\(last)|\(Int(size.width))x\(Int(size.height))|\(font.rawValue)"
        if layouts.key != key {
            layouts.key = key
            layouts.lines = [:]
        }
        var next = 0
        while layouts.lines[next] != nil && next < index { next += 1 }
        while next <= index {
            if layouts.lines[next] == nil {
                let before = next > 0 ? (layouts.lines[next - 1] ?? []) : []
                layouts.lines[next] = layout(next, avoiding: before, context: context, size: size)
            }
            next += 1
        }
        return layouts.lines[index] ?? []
    }

    /// Everything already on screen that a new star, link or label must keep clear of.
    private struct Obstacles {
        var stars: [CGPoint] = []
        var labels: [CGRect] = []
        var links: [(CGPoint, CGPoint)] = []
    }

    /// Grows a line as a path, word to word. Each star is placed only where its link crosses
    /// nothing, passes through no label or star, and where its own label has a free side.
    /// The previous line counts as an obstacle, so the two never pile up.
    private func layout(_ index: Int, avoiding previous: [PlacedWord], context: GraphicsContext, size: CGSize) -> [PlacedWord] {
        let words = lines[index].words
        guard !words.isEmpty else { return [] }

        let base = baseFontSize(size)
        // Measure each label at the biggest size it will ever be drawn.
        let textSizes = words.map { word -> CGSize in
            let biggest = base * activeScale * (isLong(word, in: lines[index]) ? longScale : 1)
            return context.resolve(Text(word.text.lowercased()).font(font.font(size: biggest))).measure(in: size)
        }
        let margin = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.12, dy: size.height * 0.12)

        var obstacles = Obstacles()
        for (k, item) in previous.enumerated() {
            obstacles.stars.append(item.center)
            obstacles.labels.append(item.label)
            if k > 0 { obstacles.links.append((previous[k - 1].center, item.center)) }
        }

        // Aim the line through the middle of the screen: pick a mostly sideways direction,
        // estimate how long the path will be, and start half that length back from the centre.
        // The previous line is an obstacle, so the two still never collide.
        let leftward = seeded(index, 3) < 0.5
        let baseHeading = (leftward ? Double.pi : 0) + (seeded(index, 5) - 0.5) * 0.8
        var heading = baseHeading
        var pathLength: CGFloat = 0
        for k in words.indices.dropFirst() {
            pathLength += max((textSizes[k - 1].width + textSizes[k].width) * 0.35, base * 3) + base
        }
        pathLength *= 0.7  // the path bends, so it spans less than its full length
        // Alternate just above and just below the middle, so back-to-back lines sit in
        // neighbouring bands instead of fighting over the same spot.
        let band: CGFloat = index % 2 == 0 ? -0.16 : 0.16
        let center = CGPoint(x: size.width / 2, y: size.height * (0.5 + band))

        var start: (CGPoint, CGRect, LabelSide)? = nil
        for attempt in 0..<40 where start == nil {
            // Nudge further from the ideal spot as attempts fail.
            let wobble = 0.04 + 0.01 * CGFloat(attempt)
            var point = CGPoint(x: center.x - cos(heading) * pathLength / 2,
                                y: center.y - sin(heading) * pathLength / 2 * 0.8)
            point.x += (seeded(index, 20 + attempt) - 0.5) * 2 * wobble * size.width
            point.y += (seeded(index, 80 + attempt) - 0.5) * 2 * wobble * size.height
            point.x = min(max(point.x, margin.minX), margin.maxX)
            point.y = min(max(point.y, margin.minY), margin.maxY)
            guard starIsFree(point, obstacles),
                  let (label, side) = freeLabel(for: point, text: textSizes[0], gap: gap(words[0], index), obstacles, size)
            else { continue }
            start = (point, label, side)
        }
        let fallback = CGPoint(x: margin.midX, y: margin.midY)
        let first = start ?? (fallback, labelArea(fallback, textSizes[0], side: .below, gap: 22), .below)

        var placed = [PlacedWord(word: words[0], center: first.0, label: first.1, side: first.2)]
        obstacles.stars.append(first.0)
        obstacles.labels.append(first.1)

        let previousCount = (stars: previous.count, labels: previous.count, links: max(previous.count - 1, 0))
        var previousCleared = false

        for k in words.indices.dropFirst() {
            // The previous line is gone once it has faded, so later words may use its space.
            if !previousCleared && words[k].start >= lines[index].start + fadeSeconds {
                obstacles.stars.removeFirst(previousCount.stars)
                obstacles.labels.removeFirst(previousCount.labels)
                obstacles.links.removeFirst(previousCount.links)
                previousCleared = true
            }
            let from = placed[k - 1].center
            let step = max((textSizes[k - 1].width + textSizes[k].width) * 0.35, base * 3) + base * 2 * seeded(index * 100 + k, 1)
            var found: PlacedWord? = nil

            // Search around the heading, widening the angle and reaching further as tries fail.
            for attempt in 0..<160 where found == nil {
                let ring = Double(attempt / 16)  // 0 to 9: each ring reaches 25% further
                let spread = 0.9 + Double(attempt % 16) * 0.35  // up to a full circle
                let angle = heading + (seeded(index * 100 + k, 10 + attempt) - 0.5) * spread
                let distance = step * (1 + 0.25 * ring)
                let point = CGPoint(x: from.x + cos(angle) * distance, y: from.y + sin(angle) * distance * 0.8)

                // The previous word may move its label once it knows where this link goes,
                // so check against everything except that label.
                var others = obstacles
                others.labels.removeLast()
                guard margin.contains(point), starIsFree(point, others), linkIsFree(from, point, others) else { continue }
                others.links.append((from, point))
                others.stars.append(point)
                guard let (previousLabel, previousSide) = freeLabel(for: from, text: textSizes[k - 1],
                                                                     gap: gap(words[k - 1], index), others, size)
                else { continue }
                others.labels.append(previousLabel)
                guard let (label, side) = freeLabel(for: point, text: textSizes[k], gap: gap(words[k], index), others, size)
                else { continue }

                placed[k - 1].label = previousLabel
                placed[k - 1].side = previousSide
                obstacles.labels[obstacles.labels.count - 1] = previousLabel
                found = PlacedWord(word: words[k], center: point, label: label, side: side)
                // Follow the bend a little, but lean back toward the line's direction so it
                // stays in its band instead of wandering off.
                heading = 0.5 * angle + 0.5 * baseHeading
            }

            // ponytail: a crowded screen can leave no clean spot; the word then takes any free one, link rules relaxed.
            if found == nil {
                var nearest = CGFloat.infinity
                for attempt in 0..<80 {
                    let point = CGPoint(x: margin.minX + margin.width * seeded(index * 100 + k, 200 + attempt),
                                        y: margin.minY + margin.height * seeded(index * 100 + k, 300 + attempt))
                    let distance = hypot(point.x - from.x, point.y - from.y)
                    guard distance < nearest, starIsFree(point, obstacles),
                          let (label, side) = freeLabel(for: point, text: textSizes[k], gap: gap(words[k], index), obstacles, size)
                    else { continue }
                    found = PlacedWord(word: words[k], center: point, label: label, side: side)  // the closest free spot wins
                    nearest = distance
                }
            }
            let point = found?.center ?? from
            let item = found ?? PlacedWord(word: words[k], center: from,
                                           label: labelArea(from, textSizes[k], side: .below, gap: 22), side: .below)
            obstacles.links.append((from, point))
            obstacles.stars.append(point)
            obstacles.labels.append(item.label)
            placed.append(item)
        }
        return placed
    }

    /// How far a label sits from its star: past the star at its biggest, more for held notes.
    private func gap(_ word: Word, _ index: Int) -> CGFloat {
        return isLong(word, in: lines[index]) ? 32 : 22
    }

    /// How far text keeps from any other star: a held note's star at full kick is about 25 pt across.
    private let starClearance: CGFloat = 34

    /// A star needs room: away from other stars and outside every label.
    private func starIsFree(_ point: CGPoint, _ obstacles: Obstacles) -> Bool {
        let tooClose = obstacles.stars.contains { hypot($0.x - point.x, $0.y - point.y) < 72 }
        let inLabel = obstacles.labels.contains { $0.insetBy(dx: -starClearance, dy: -starClearance).contains(point) }
        return !tooClose && !inLabel
    }

    /// A link may not cross another link, cut through a label, or graze a star it does not join.
    private func linkIsFree(_ from: CGPoint, _ to: CGPoint, _ obstacles: Obstacles) -> Bool {
        let crosses = obstacles.links.contains { link in
            let sharesEnd = link.0 == from || link.1 == from
            return !sharesEnd && segmentsCross(from, to, link.0, link.1)
        }
        let throughLabel = obstacles.labels.contains { segment(from, to, hits: $0.insetBy(dx: -4, dy: -4)) }
        let throughStar = obstacles.stars.contains { star in
            star != from && segment(from, to, hits: CGRect(x: star.x - 12, y: star.y - 12, width: 24, height: 24))
        }
        return !crosses && !throughLabel && !throughStar
    }

    /// Like a star chart: the first side of the star where the label touches no link, label or
    /// other star and stays on screen. Below is tried first because it reads best.
    private func freeLabel(for star: CGPoint, text: CGSize, gap: CGFloat, _ obstacles: Obstacles,
                           _ size: CGSize) -> (CGRect, LabelSide)? {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        for side in LabelSide.allCases {
            let rect = labelArea(star, text, side: side, gap: gap)
            let padded = rect.insetBy(dx: -8, dy: -4)
            let hitsLink = obstacles.links.contains { segment($0.0, $0.1, hits: padded) }
            let hitsLabel = obstacles.labels.contains { $0.intersects(padded) }
            let hitsStar = obstacles.stars.contains { $0 != star && rect.insetBy(dx: -starClearance, dy: -starClearance).contains($0) }
            if !hitsLink && !hitsLabel && !hitsStar && screen.contains(rect) {
                return (rect, side)
            }
        }
        return nil
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

    // MARK: Drawing

    private func drawLine(_ index: Int, context: GraphicsContext, size: CGSize, fade: Double) {
        guard fade > 0 else { return }
        var layer = context
        layer.opacity = fade
        layer.translateBy(x: 0, y: -(1 - fade) * 50)

        let line = lines[index]
        let baseFont = baseFontSize(size)
        let placed = placedWords(index, context: context, size: size)

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
            if long { radius *= 1.4 }

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
            var fontSize = baseFont * (current ? activeScale : 1)
            if long { fontSize *= longScale }  // smaller than Verci's x2.4 so held notes fit their label space
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
