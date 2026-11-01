import SwiftUI

/// Shared bits for the line-at-a-time Canvas styles (Branches, Web).
struct LineMoment {
    let index: Int          // which lyric line
    let line: LyricLine
    let start: Double       // first word start
    let end: Double         // last word end
    let fadeOut: Double     // 0 while the line is live, rising to 1 over 0.8 s after it ends
    let averageLength: Double
}

/// The line being sung (or just finished), with its fade-out progress.
func currentMoment(lines: [LyricLine], at time: Double) -> LineMoment? {
    var found: Int? = nil
    for (index, line) in lines.enumerated() where (line.words.first?.start ?? line.start) <= time {
        found = index
    }
    guard let found, let first = lines[found].words.first, let last = lines[found].words.last else { return nil }
    let line = lines[found]
    let average = line.words.reduce(0) { $0 + max($1.end - $1.start, 0.08) } / Double(line.words.count)
    return LineMoment(index: found, line: line, start: first.start, end: last.end,
                      fadeOut: smoothstep((time - last.end) / 0.8), averageLength: average)
}

/// The landing spring used by every style: starts at -1, swings, settles in about half a second.
func landingKick(_ age: Double) -> Double {
    if age < 0 { return 0 }
    return exp(-age / 0.16) * cos(15 * age + .pi)
}

/// Draws a word label with the shared landing motion: tilt with the kick, 30% pop, 0.1 s fade-in.
func drawLabel(_ text: String, at point: CGPoint, size: CGFloat, color: Color, font: LyricFont, age: Double,
               opacity: Double, anchor: UnitPoint, context: GraphicsContext) {
    var layer = context
    layer.opacity = opacity * clamp(age / 0.1)
    layer.translateBy(x: point.x, y: point.y)
    layer.rotate(by: .degrees(8 * landingKick(age)))
    let pop = 1 + 0.3 * exp(-age / 0.1)
    layer.scaleBy(x: pop, y: pop)
    layer.draw(context.resolve(Text(text.lowercased()).font(font.font(size: size)).foregroundStyle(color)),
               at: .zero, anchor: anchor)
}

/// A circle drawn as a ring.
func ringPath(_ center: CGPoint, diameter: CGFloat) -> Path {
    return Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
}

/// A polyline from fraction `from` to `to` of its length (both 0...1), for drawing lines that grow.
func partialPath(_ points: [CGPoint], from: Double, to: Double) -> Path {
    var path = Path()
    guard points.count > 1, to > from else { return path }
    let segments = Double(points.count - 1)
    func point(at t: Double) -> CGPoint {
        let x = clamp(t) * segments
        let i = min(Int(x), points.count - 2)
        let f = x - Double(i)
        return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f,
                       y: points[i].y + (points[i + 1].y - points[i].y) * f)
    }
    path.move(to: point(at: from))
    // Every corner strictly between `from` and `to`, counted in whole points so the loop always ends.
    let firstCorner = Int(floor(clamp(from) * segments)) + 1
    let lastCorner = Int(ceil(clamp(to) * segments)) - 1
    if firstCorner <= lastCorner {
        for corner in firstCorner...lastCorner {
            path.addLine(to: points[corner])
        }
    }
    path.addLine(to: point(at: to))
    return path
}

// MARK: - Branches

/// Branches: a wavy line grows across the screen through the lyric line. Each word sprouts a curved
/// branch above or below it, with a node at the tip and the word beside the node.
///
/// Studied from Verci's decompiled Branches scene, written fresh here:
/// - the stem is a 73-point curve over the middle 78% of the width, made of three sines, flat at the ends;
/// - it grows with the line (ease-out), a glowing head leads it, and three ghost copies trail the head;
/// - branches alternate up and down (30% chance of flipping), grow with an ease-out over the word;
/// - the word being sung gets a pulsing ring; eight faint code glyphs drift in the background.
struct BranchesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    var settings = StyleSettings()

    var body: some View {
        TimelineView(.animation) { timeline in
            let painter = BranchesPainter(lines: model.lyrics?.lines ?? [],
                                          songTime: settings.songTime(player: player, model: model, at: timeline.date),
                                          clock: timeline.date.timeIntervalSinceReferenceDate,
                                          colors: settings.colors(palette: model.palette), font: settings.font)
            Canvas { context, size in painter.draw(context, size: size) }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

struct BranchesPainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double
    let colors: LyricColors
    let font: LyricFont

    func draw(_ context: GraphicsContext, size: CGSize) {
        var scene = context
        scene.addFilter(.shadow(color: .black.opacity(0.45), radius: 6))
        drawGlyphs(scene, size: size)

        guard let moment = currentMoment(lines: lines, at: songTime) else { return }
        let height = size.height
        let span = max(0.1, moment.end - moment.start)
        let stem = stemPoints(moment, size: size)

        // The stem grows with the line and is erased from the start once the line is over.
        let p = clamp((songTime - moment.start) / span)
        let grown = 1 - pow(1 - p, 2)
        scene.stroke(partialPath(stem, from: moment.fadeOut * grown, to: grown),
                     with: .color(colors.text.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Branches, nodes and words.
        let shapes = branchShapes(moment, stem: stem, size: size)
        for (i, word) in moment.line.words.enumerated() {
            drawBranch(word, shape: shapes[i], moment: moment, stem: stem, size: size, context: scene)
        }

        // The glowing head, with three ghosts trailing a little behind in time.
        let pulse = 1 + 0.2 * (0.5 + 0.5 * sin(3.4 * clock))
        let head = pointOn(stem, at: grown)
        if moment.fadeOut == 0 {
            for n in 1...3 {
                let lagged = 1 - pow(1 - clamp((songTime - 0.016 * Double(n) - moment.start) / span), 2)
                let ghost = pointOn(stem, at: lagged)
                let diameter = 4.05 / sqrt(Double(n)) * 2
                scene.fill(ringPath(ghost, diameter: diameter),
                           with: .color(colors.highlight.opacity(min(8 * grown, 1) * 0.5 / Double(n))))
            }
            var glow = scene
            glow.addFilter(.blur(radius: 6))
            glow.fill(ringPath(head, diameter: 18 * pulse), with: .color(colors.highlight.opacity(0.5)))
            scene.fill(ringPath(head, diameter: 9 * pulse), with: .color(colors.highlight.opacity(0.9)))
        } else {
            // When the line ends, a ring spreads from the head and fades.
            let f = moment.fadeOut
            scene.stroke(ringPath(head, diameter: 9 + 63 * (1 - pow(1 - f, 2))),
                         with: .color(colors.highlight.opacity(1 - f)), lineWidth: 2.5)
        }
        _ = height
    }

    /// The stem: x across the middle 78%, y the sum of three sines, pinned flat at both ends.
    private func stemPoints(_ moment: LineMoment, size: CGSize) -> [CGPoint] {
        let seed = Int(moment.start * 1000)
        let phase = 2 * Double.pi * seeded(seed, 1)
        let wobble = 0.8 + 0.4 * seeded(seed, 2)
        let left = size.width * 0.11
        var points: [CGPoint] = []
        for i in 0...72 {
            let t = Double(i) / 72
            let wave = sin(phase + wobble * 2.6 * 2 * Double.pi * t)
                + 0.45 * sin(1.9 * phase + 2 * Double.pi * 2.35 * t - 1.84 * clock)
                + 0.2 * sin(1.84 * 1.35 * clock + 2 * Double.pi * 3.65 * t)
            let y = size.height / 2 + size.height * 0.06 * sin(Double.pi * t) * wave
            points.append(CGPoint(x: left + size.width * 0.78 * t, y: y))
        }
        return points
    }

    private func pointOn(_ points: [CGPoint], at t: Double) -> CGPoint {
        let x = clamp(t) * Double(points.count - 1)
        let i = min(Int(x), points.count - 2)
        let f = x - Double(i)
        return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f, y: points[i].y + (points[i + 1].y - points[i].y) * f)
    }

    /// Where a branch goes before any spring: its side (-1 up, 1 down) and its tip offset.
    struct BranchShape {
        var side: Double
        var dx: Double
        var dy: Double
    }

    /// Picks every branch's direction for the line, moving a tip sideways or further out when its
    /// word (at its biggest) would land on a word already placed, so labels never pile up.
    private func branchShapes(_ moment: LineMoment, stem: [CGPoint], size: CGSize) -> [BranchShape] {
        let span = max(0.1, moment.end - moment.start)
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        var labels: [CGRect] = []
        var shapes: [BranchShape] = []
        for (i, word) in moment.line.words.enumerated() {
            let seed = Int(word.start * 1000)
            let along = min(max(((word.start + word.end) / 2 - moment.start) / span, 0.04), 0.96)
            let anchor = pointOn(stem, at: along)
            var side: Double = i % 2 == 0 ? -1 : 1
            if seeded(seed, 3) < 0.3 { side = -side }

            let long = max(0.08, word.end - word.start) >= 1.6 * moment.averageLength
            let biggest = size.height * 0.034 * 1.75 * (long ? 1.8 : 1)
            let labelWidth = CGFloat(word.text.count) * biggest * 0.58
            let labelHeight = biggest * 1.2

            var shape = BranchShape(side: side, dx: (seeded(seed, 4) * 2 - 1) * 0.1 * size.width,
                                    dy: side * (0.75 + 0.5 * seeded(seed, 5)) * 0.26 * size.height)
            var rect = CGRect.zero
            // Try the planned spot, then slide sideways, then reach further out, then the other side.
            for attempt in 0..<12 {
                if attempt > 0 {
                    let flip = attempt >= 8 ? -side : side
                    let slide = Double((attempt % 4) - 2) * 0.06 * size.width
                    let reach = 0.26 * size.height * (0.75 + 0.15 * Double(attempt % 8))
                    shape = BranchShape(side: flip, dx: slide, dy: flip * reach)
                }
                let tip = CGPoint(x: anchor.x + shape.dx, y: anchor.y + shape.dy)
                let middle = CGPoint(x: tip.x, y: tip.y + shape.side * (biggest * 0.9 + 9.6))
                rect = CGRect(x: middle.x - labelWidth / 2, y: middle.y - labelHeight / 2, width: labelWidth, height: labelHeight)
                if screen.contains(rect) && !labels.contains(where: { $0.insetBy(dx: -8, dy: -4).intersects(rect) }) {
                    break
                }
            }
            labels.append(rect)
            shapes.append(shape)
        }
        return shapes
    }

    private func drawBranch(_ word: Word, shape: BranchShape, moment: LineMoment, stem: [CGPoint], size: CGSize,
                            context: GraphicsContext) {
        let age = songTime - word.start
        let length = max(0.08, word.end - word.start)
        let q = clamp(age / length)
        guard q > 0 else { return }  // branches appear only once their word starts

        let span = max(0.1, moment.end - moment.start)
        let along = min(max(((word.start + word.end) / 2 - moment.start) / span, 0.04), 0.96)
        let anchor = pointOn(stem, at: along)

        // Up or down (alternating, 30% chance of breaking the pattern), springing out on landing.
        let side = shape.side
        let kick = landingKick(age)
        let dx = shape.dx
        let dy = shape.dy * (1 + 0.35 * kick)
        let tip = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        let control = CGPoint(x: anchor.x + 0.4 * dx, y: anchor.y + 0.85 * dy)  // bends out, then over

        // A quadratic curve, sampled so it can grow from the stem.
        var curve: [CGPoint] = []
        for j in 0...20 {
            let t = Double(j) / 20
            let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
            curve.append(CGPoint(x: a * anchor.x + b * control.x + c * tip.x, y: a * anchor.y + b * control.y + c * tip.y))
        }
        let grow = (1 - moment.fadeOut) * (1 - pow(1 - q, 3))
        let active = songTime >= word.start && songTime < word.end + 0.2
        context.stroke(partialPath(curve, from: 0, to: grow),
                       with: .color(colors.highlight.opacity(active ? 0.7 : 0.38 * 0.7)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        guard grow > 0.95 || (moment.fadeOut > 0 && moment.fadeOut < 0.5) else { return }
        var tipLayer = context
        tipLayer.opacity = 1 - moment.fadeOut
        let node = 6 * (1 + 0.35 * exp(-age / 0.12))
        tipLayer.fill(ringPath(tip, diameter: node), with: .color(active ? colors.highlight : colors.text))
        if active {
            let phase = (age * 1.2).truncatingRemainder(dividingBy: 1)
            tipLayer.stroke(ringPath(tip, diameter: 6 * (1 + 4.5 * phase)),
                            with: .color(colors.highlight.opacity(0.8 * (1 - phase))), lineWidth: 1.8)
        }

        let long = length >= 1.6 * moment.averageLength
        // ponytail: Verci's x2.9 for held notes made labels collide; 1.8 keeps them readable.
        let labelSize = size.height * 0.034 * (active ? 1.75 : 1) * (long ? 1.8 : 1)
        let labelPoint = CGPoint(x: tip.x, y: tip.y + side * (labelSize * 0.9 + 9.6))
        drawLabel(word.text, at: labelPoint, size: labelSize, color: active ? colors.text : colors.secondary, font: font,
                  age: age, opacity: (active ? 1 : 0.7) * (1 - moment.fadeOut), anchor: .center, context: tipLayer)
    }

    /// Eight faint code characters drifting in the background.
    private func drawGlyphs(_ context: GraphicsContext, size: CGSize) {
        let glyphs = ["/", "<", ">", "·", "+", "—"]
        for i in 0..<8 {
            let u = seeded(700 + i, 1), v = seeded(700 + i, 2)
            let x = u * size.width + size.width * 0.015 * sin(2 * Double.pi * u + 0.11 * clock)
            let y = v * size.height + size.height * 0.02 * sin(3.4 * Double.pi * u + 0.09 * clock)
            let glyph = glyphs[Int(seeded(700 + i, 3) * 6) % 6]
            let text = Text(glyph).font(.system(size: size.height * 0.03, weight: .light, design: .monospaced))
                .foregroundStyle(colors.text.opacity(0.14))
            context.draw(context.resolve(text), at: CGPoint(x: x, y: y))
        }
    }
}

// MARK: - Web

/// Web: a spider web of 12 spokes and 4 rings. Each sung word spins a silk strand out from the hub
/// to a node of the web, and the word lands at the end of it.
///
/// Studied from Verci's decompiled Web scene, written fresh here:
/// - nodes sit on 12 slightly irregular spokes at 30%, 55%, 78% and 100% of the radius, stretched wide;
/// - a strand sags a little to one side and springs when its word lands;
/// - the word being sung is bright with a pulsing ring; sung words dim to about a quarter.
struct WebView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    var settings = StyleSettings()

    var body: some View {
        TimelineView(.animation) { timeline in
            let painter = WebPainter(lines: model.lyrics?.lines ?? [],
                                     songTime: settings.songTime(player: player, model: model, at: timeline.date),
                                     clock: timeline.date.timeIntervalSinceReferenceDate,
                                     colors: settings.colors(palette: model.palette), font: settings.font)
            Canvas { context, size in painter.draw(context, size: size) }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

struct WebPainter {
    let lines: [LyricLine]
    let songTime: Double
    let clock: Double
    let colors: LyricColors
    let font: LyricFont

    let rings: [Double] = [0.3, 0.55, 0.78, 1.0]

    struct Node {
        var point: CGPoint
        var angle: Double
        var ring: Int
        var spoke: Int
    }

    func draw(_ context: GraphicsContext, size: CGSize) {
        guard let moment = currentMoment(lines: lines, at: songTime) else { return }
        var scene = context
        scene.addFilter(.shadow(color: .black.opacity(0.5), radius: 6))
        scene.opacity = 1 - moment.fadeOut
        // The whole web sways gently.
        scene.translateBy(x: size.height * 0.0076 * sin(0.4 * clock), y: size.height * 0.0076 * sin(0.31 * clock + 1))

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.height * 0.4
        let seed = Int(moment.start * 1000)
        let nodes = webNodes(seed: seed, center: center, radius: radius)

        // The faint frame: spokes and rings.
        var frame = Path()
        for spoke in 0..<12 {
            frame.move(to: center)
            frame.addLine(to: nodes.first { $0.spoke == spoke && $0.ring == 3 }!.point)
        }
        for ring in 0..<4 {
            let around = (0..<12).map { s in nodes.first { $0.spoke == s && $0.ring == ring }!.point }
            frame.move(to: around[0])
            for p in around.dropFirst() { frame.addLine(to: p) }
            frame.closeSubpath()
        }
        scene.stroke(frame, with: .color(colors.text.opacity(0.1)), lineWidth: 0.8)

        // Words take nodes from left to right, spread evenly over the 48.
        let byX = nodes.sorted { $0.point.x < $1.point.x }
        let words = moment.line.words
        for (i, word) in words.enumerated() {
            let slot = min(Int((Double(i) + 0.5) * 48 / Double(words.count)), 47)
            drawStrand(word, to: byX[slot], center: center, radius: radius, moment: moment, size: size, context: scene)
        }
    }

    /// 48 nodes: 12 spokes (each nudged a little off even spacing) times 4 rings, stretched 1.25x wide.
    private func webNodes(seed: Int, center: CGPoint, radius: Double) -> [Node] {
        let turn = 2 * Double.pi * seeded(seed, 1)
        var nodes: [Node] = []
        for spoke in 0..<12 {
            let angle = turn + 2 * Double.pi * Double(spoke) / 12 + (seeded(seed, 10 + spoke) - 0.5) * 0.09
            for (ring, scale) in rings.enumerated() {
                let point = CGPoint(x: center.x + cos(angle) * radius * scale * 1.25, y: center.y + sin(angle) * radius * scale)
                nodes.append(Node(point: point, angle: angle, ring: ring, spoke: spoke))
            }
        }
        return nodes
    }

    private func drawStrand(_ word: Word, to node: Node, center: CGPoint, radius: Double, moment: LineMoment,
                            size: CGSize, context: GraphicsContext) {
        let age = songTime - word.start
        guard age >= 0 else { return }
        let length = max(0.08, word.end - word.start)
        let q = 1 - pow(1 - clamp(age / length), 3)
        let kick = 1 + 0.21 * landingKick(age)
        let active = songTime >= word.start && songTime < word.end + 0.2
        let state = active ? 1.0 : 0.26

        // 13 points from the hub, sagging sideways in the middle, the sag side set by the spoke.
        let scale = rings[node.ring]
        let sagSide: Double = node.spoke % 2 == 0 ? 1 : -1
        var strand: [CGPoint] = []
        for j in 0...12 {
            let t = Double(j) / 12
            let distance = kick * scale * t * radius
            let sag = 0.05 * radius * sin(Double.pi * t) * kick * sagSide
            let along = CGPoint(x: cos(node.angle) * distance * 1.25, y: sin(node.angle) * distance)
            let across = CGPoint(x: -sin(node.angle) * sag, y: cos(node.angle) * sag)
            strand.append(CGPoint(x: center.x + along.x + across.x, y: center.y + along.y + across.y))
        }
        context.stroke(partialPath(strand, from: 0, to: q), with: .color(colors.highlight.opacity(max(0.3, state) * 0.85)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        guard q >= 0.85, let end = strand.last else { return }

        context.fill(ringPath(end, diameter: 7 * (1 + 0.4 * exp(-age / 0.16))),
                     with: .color(active ? colors.highlight : colors.text.opacity(0.6)))
        if active {
            let phase = (age * 1.2).truncatingRemainder(dividingBy: 1)
            context.stroke(ringPath(end, diameter: 7 * (1 + 5 * phase)), with: .color(colors.highlight.opacity(0.8 * (1 - phase))),
                           lineWidth: 2)
        }

        let long = length >= 1.6 * moment.averageLength
        let labelSize = size.height * 0.032 * (active ? 1.8 : 1) * (long ? 1.6 : 1)
        // The word sits just beyond the node, on the outward side.
        let outward = CGPoint(x: end.x + cos(node.angle) * (labelSize * 0.9 + 10) * 1.25,
                              y: end.y + sin(node.angle) * (labelSize * 0.9 + 10))
        drawLabel(word.text, at: outward, size: labelSize, color: active ? colors.text : colors.secondary, font: font,
                  age: age, opacity: active ? 1 : 0.75, anchor: .center, context: context)
    }
}
