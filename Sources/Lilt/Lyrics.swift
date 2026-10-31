import Foundation

struct Word {
    var text: String
    var start: Double  // seconds
    var end: Double
}

struct LyricLine {
    var start: Double
    var end: Double
    var words: [Word]
}

struct Lyrics {
    var lines: [LyricLine]
    var wordTimed: Bool  // false means the word times were estimated from line times
}

/// Finds Apple Music lyrics for a track through Cider, with a small in-memory cache.
@MainActor
final class LyricsStore {
    private let cider: CiderClient
    private var cache: [String: Lyrics] = [:]
    private var catalogIds: [String: String] = [:]  // "title|artist" -> catalog id
    private var storefront: String?

    init(cider: CiderClient) {
        self.cider = cider
    }

    /// The track's Apple Music catalog id: from the player if it gave one, otherwise a search.
    private func catalogId(for track: Track, storefront: String) async -> String? {
        if let id = track.catalogId { return id }
        let key = track.title + "|" + track.artist
        if let known = catalogIds[key] { return known }
        let found = await searchCatalogId(title: track.title, artist: track.artist, storefront: storefront)
        catalogIds[key] = found
        return found
    }

    /// Apple's colours for the album art: background first, then four text colours, as "rrggbb".
    func artworkColors(for track: Track) async -> [String] {
        let store = await storefrontId()
        guard let id = await catalogId(for: track, storefront: store),
              let json = await cider.amapi("/v1/catalog/\(store)/songs/\(id)")
        else { return [] }
        let apple = json["data"] as? [String: Any]
        let song = (apple?["data"] as? [[String: Any]])?.first
        let attributes = song?["attributes"] as? [String: Any]
        let artwork = attributes?["artwork"] as? [String: Any]
        var colors: [String] = []
        for key in ["bgColor", "textColor1", "textColor2", "textColor3", "textColor4"] {
            if let hex = artwork?[key] as? String { colors.append(hex) }
        }
        return colors
    }

    func lyrics(for track: Track) async -> Lyrics? {
        let store = await storefrontId()
        guard let id = await catalogId(for: track, storefront: store) else { return nil }
        if let cached = cache[id] { return cached }

        // syllable-lyrics has a time for every word; plain lyrics only has a time per line.
        for kind in ["syllable-lyrics", "lyrics"] {
            guard let json = await cider.amapi("/v1/catalog/\(store)/songs/\(id)/\(kind)"),
                  let ttml = findString(key: "ttml", in: json)
            else { continue }
            let lyrics = parseTTML(unescapeHTML(ttml))
            if !lyrics.lines.isEmpty {
                cache[id] = lyrics
                return lyrics
            }
        }
        return nil
    }

    private func storefrontId() async -> String {
        if let storefront { return storefront }
        let json = await cider.amapi("/v1/me/storefront")
        let apple = json?["data"] as? [String: Any]
        let first = (apple?["data"] as? [[String: Any]])?.first
        guard let id = first?["id"] as? String else { return "us" }  // not cached, so the next call asks again
        storefront = id
        return id
    }

    /// True when Cider can get an answer from Apple Music at all.
    func appleMusicReachable() async -> Bool {
        return await cider.amapi("/v1/me/storefront") != nil
    }

    private func searchCatalogId(title: String, artist: String, storefront: String) async -> String? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        // URLQueryItem leaves "+" alone, but Apple reads it as a space.
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")

        let json = await cider.amapi("/v1/catalog/\(storefront)/search?\(query)")
        let apple = json?["data"] as? [String: Any]
        let results = apple?["results"] as? [String: Any]
        let songs = results?["songs"] as? [String: Any]
        let first = (songs?["data"] as? [[String: Any]])?.first
        return first?["id"] as? String
    }
}

/// Looks through nested JSON for the first string stored under `key`.
func findString(key: String, in value: Any) -> String? {
    if let dict = value as? [String: Any] {
        if let found = dict[key] as? String { return found }
        for child in dict.values {
            if let found = findString(key: key, in: child) { return found }
        }
    }
    if let array = value as? [Any] {
        for child in array {
            if let found = findString(key: key, in: child) { return found }
        }
    }
    return nil
}

/// Cider HTML-escapes every string it proxies, tags included. Undo that once.
func unescapeHTML(_ text: String) -> String {
    if text.hasPrefix("<") { return text }  // already raw XML
    var result = text
    result = result.replacingOccurrences(of: "&lt;", with: "<")
    result = result.replacingOccurrences(of: "&gt;", with: ">")
    result = result.replacingOccurrences(of: "&quot;", with: "\"")
    result = result.replacingOccurrences(of: "&#39;", with: "'")
    result = result.replacingOccurrences(of: "&#x27;", with: "'")
    // Last, so "&amp;amp;" becomes "&amp;", which is still valid XML.
    result = result.replacingOccurrences(of: "&amp;", with: "&")
    return result
}

/// Turns "0.080", "13.141", "2:27.610", "00:00:10.050" or "12.3s" into seconds.
func parseTime(_ text: String?) -> Double? {
    guard var text, !text.isEmpty else { return nil }
    if text.hasSuffix("s") { text.removeLast() }
    var seconds = 0.0
    for part in text.split(separator: ":") {
        guard let value = Double(part) else { return nil }
        seconds = seconds * 60 + value
    }
    return seconds
}

func parseTTML(_ ttml: String) -> Lyrics {
    let reader = TTMLReader()
    let parser = XMLParser(data: Data(ttml.utf8))
    parser.delegate = reader
    parser.parse()
    return Lyrics(lines: reader.lines, wordTimed: reader.sawTimedWords)
}

/// Apple's TTML: each <p> is a line. Word-timed lyrics put each word or syllable in a
/// timed <span>; syllables of one word sit next to each other with no space between.
final class TTMLReader: NSObject, XMLParserDelegate {
    var lines: [LyricLine] = []
    var sawTimedWords = false

    private var inLine = false
    private var lineStart = 0.0
    private var lineEnd = 0.0
    private var lineWords: [Word] = []
    private var lineText = ""  // text outside timed spans

    private var wordStart: Double?
    private var wordEnd = 0.0
    private var wordText = ""
    private var spaceBeforeNextWord = true

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "p" {
            inLine = true
            lineStart = parseTime(attributes["begin"]) ?? 0
            lineEnd = parseTime(attributes["end"]) ?? lineStart + 3
            lineWords = []
            lineText = ""
            spaceBeforeNextWord = true
        } else if name == "span", inLine, let begin = parseTime(attributes["begin"]) {
            wordStart = begin
            wordEnd = parseTime(attributes["end"]) ?? begin + 0.3
            wordText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inLine else { return }
        if wordStart != nil {
            wordText += string
        } else {
            lineText += string
            if string.contains(where: { $0.isWhitespace }) { spaceBeforeNextWord = true }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "span", let start = wordStart {
            finishWord(start: start)
            wordStart = nil
        } else if name == "p" {
            if lineWords.isEmpty {
                lineWords = estimateWords(lineText, start: lineStart, end: lineEnd)
            } else {
                sawTimedWords = true
            }
            if !lineWords.isEmpty {
                lines.append(LyricLine(start: lineStart, end: lineEnd, words: lineWords))
            }
            inLine = false
        }
    }

    private func finishWord(start: Double) {
        let trimmed = wordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsWithSpace = wordText.first?.isWhitespace ?? false
        let endsWithSpace = wordText.last?.isWhitespace ?? false
        if trimmed.isEmpty { return }

        if !spaceBeforeNextWord && !startsWithSpace && !lineWords.isEmpty {
            // A syllable glued to the previous one: same word, longer time.
            lineWords[lineWords.count - 1].text += trimmed
            lineWords[lineWords.count - 1].end = wordEnd
        } else {
            lineWords.append(Word(text: trimmed, start: start, end: wordEnd))
        }
        spaceBeforeNextWord = endsWithSpace
    }
}

/// Spreads a line's time over its words, longer words getting more time.
func estimateWords(_ text: String, start: Double, end: Double) -> [Word] {
    let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let totalLetters = pieces.reduce(0) { $0 + $1.count }
    guard totalLetters > 0 else { return [] }

    var words: [Word] = []
    var time = start
    for piece in pieces {
        let share = (end - start) * Double(piece.count) / Double(totalLetters)
        words.append(Word(text: piece, start: time, end: time + share))
        time += share
    }
    return words
}
