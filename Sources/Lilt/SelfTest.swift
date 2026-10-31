import SwiftUI

/// `Lilt --selftest`: checks the lyric parsing, the part most likely to break quietly.
func runSelfTest() {
    let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
    <p begin="1.0" end="3.0"><span begin="1.0" end="1.4">Hel</span><span begin="1.4" end="1.8">lo</span> <span begin="2.0" end="3.0">world</span></p>
    <p begin="1:02.5" end="1:04.5">two words</p>
    </div></body></tt>
    """
    let lyrics = parseTTML(ttml)
    precondition(lyrics.lines.count == 2, "expected 2 lines")
    precondition(lyrics.wordTimed, "first line has timed spans")

    let first = lyrics.lines[0].words
    precondition(first.map { $0.text } == ["Hello", "world"], "syllables should join into one word: \(first.map { $0.text })")
    precondition(first[0].start == 1.0 && first[0].end == 1.8, "joined word keeps first start and last end")

    let second = lyrics.lines[1]
    precondition(second.start == 62.5, "1:02.5 is 62.5 seconds")
    precondition(second.words.count == 2 && abs(second.words[0].end - 63.25) < 0.001, "3 of 8 letters gets 3/8 of 2 s")

    precondition(unescapeHTML("&lt;p&gt;Rock &amp;amp; Roll&lt;/p&gt;") == "<p>Rock &amp; Roll</p>", "unescape once")
    precondition(hexFromColor(colorFromHex("#FF336680")) == "#FF336680", "hex colour round trip")
    // A muted navy album with one teal swatch: teal wins the highlight.
    let palette = AlbumPalette(hexes: ["09161d", "d2d0c0", "2aa198"])
    precondition(palette != nil && AlbumPalette(hexes: []) == nil, "palette from swatches, nil from none")
    precondition(segmentsCross(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0)), "an X crosses")
    precondition(!segmentsCross(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5)), "parallel lines do not")
    precondition(segment(CGPoint(x: -5, y: 5), CGPoint(x: 15, y: 5), hits: CGRect(x: 0, y: 0, width: 10, height: 10)), "line through a box hits it")
    precondition(parseTime("00:00:10.050") == 10.05 && parseTime("12.3s") == 12.3, "time formats")

    print("selftest ok")
}

/// `Lilt --preview out.png`: draws one frame of the constellation with sample lyrics, no music needed.
@MainActor
func renderPreview(to path: String) {
    let lines = [
        LyricLine(start: 0, end: 3, words: estimateWords("we drew the stars ourselves out of nothing", start: 0, end: 3)),
        LyricLine(start: 3, end: 6, words: estimateWords("and named them after everyone we never got to meet", start: 3, end: 6)),
    ]
    let painter = ConstellationPainter(lines: lines, songTime: 5.5, clock: 0,
                                       textColor: colorFromHex(Theme.defaultText),
                                       highlight: colorFromHex(Theme.defaultHighlight),
                                       secondary: colorFromHex(Theme.defaultSecondary),
                                       font: .sfPro)
    let frame = Canvas { context, size in painter.draw(context, size: size) }
        .frame(width: 1512, height: 982)
        .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
    let renderer = ImageRenderer(content: frame)
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("preview failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
