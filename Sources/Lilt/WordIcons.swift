import AppKit
import NaturalLanguage
import SwiftUI

/// Matches a lyric word to an SF Symbol.
///
/// 1. Apple's own symbol search terms (the same index the SF Symbols app uses), shipped in macOS.
/// 2. If that misses, the nearest words in Apple's on-device English word embedding, looked up in
///    the same index (so "darling" can find the symbol for "love").
/// Common filler words never get an icon.
final class WordIcons: @unchecked Sendable {
    static let shared = WordIcons()

    private let lock = NSLock()
    private var index: [String: String] = [:]     // search term -> symbol name
    private var cache: [String: String] = [:]     // word -> symbol name, "" for no match
    private let embedding = NLEmbedding.wordEmbedding(for: .english)

    private init() {
        index = WordIcons.loadIndex()
    }

    /// The symbol for a word, or nil. Safe to call from any thread.
    func symbol(for word: String) -> String? {
        let clean = word.lowercased().filter { $0.isLetter }
        guard clean.count > 2, !stopWords.contains(clean) else { return nil }

        lock.lock()
        let cached = cache[clean]
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }

        var found = lookup(candidates(clean))
        if found == nil, let embedding {
            // Close words in meaning, nearest first, as long as they are really close.
            search: for candidate in candidates(clean) where embedding.contains(candidate) {
                for (neighbour, distance) in embedding.neighbors(for: candidate, maximumCount: 20) where distance < 0.9 {
                    if let symbol = lookup([neighbour.lowercased()]) {
                        found = symbol
                        break search
                    }
                }
            }
        }

        lock.lock()
        cache[clean] = found ?? ""
        lock.unlock()
        return found
    }

    /// Works out a whole song's icons in the background, so drawing never waits on the embedding.
    func warm(_ lines: [LyricLine]) {
        let words = lines.flatMap { $0.words.map(\.text) }
        DispatchQueue.global(qos: .utility).async {
            for word in words { _ = self.symbol(for: word) }
        }
    }

    private func lookup(_ terms: [String]) -> String? {
        for term in terms {
            if let name = index[term], NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return nil
    }

    /// The word plus simple base forms: "dreams" -> "dream", "dancing" -> "danc"/"dance", "runnin" -> "running".
    private func candidates(_ word: String) -> [String] {
        var forms = [word]
        if word.hasSuffix("s") { forms.append(String(word.dropLast())) }
        if word.hasSuffix("ing") {
            let stem = String(word.dropLast(3))
            forms += [stem, stem + "e"]
        }
        if word.hasSuffix("ed") {
            let stem = String(word.dropLast(2))
            forms += [stem, stem + "e"]
        }
        if word.hasSuffix("in") { forms.append(word + "g") }
        return forms.filter { $0.count >= 2 }
    }

    /// Reads macOS's SF Symbols search index and turns it around: term -> symbol.
    /// When several symbols share a term, the shortest name wins ("heart" over "heart.circle.fill").
    private static func loadIndex() -> [String: String] {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_search.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String]]
        else { return [:] }

        var index: [String: String] = [:]
        let names = plist.keys.sorted { ($0.count, $0) < ($1.count, $1) }
        for name in names {
            // Skip right-to-left and script variants like "character.ar".
            if name.contains(".ar") || name.contains(".hi") || name.contains("rtl") { continue }
            var terms = plist[name] ?? []
            if let base = name.split(separator: ".").first { terms.append(String(base)) }
            for term in terms {
                let key = term.lowercased()
                if index[key] == nil { index[key] = name }
            }
        }
        return index
    }
}

/// Words too common to deserve an icon.
private let stopWords: Set<String> = [
    "the", "and", "but", "for", "nor", "yet", "you", "your", "yours", "she", "her", "hers", "him", "his",
    "they", "them", "their", "our", "ours", "its", "this", "that", "these", "those", "what", "who", "whom",
    "which", "when", "where", "why", "how", "all", "any", "some", "too", "very", "just", "not", "now",
    "then", "than", "here", "there", "with", "without", "from", "into", "onto", "upon", "about", "over",
    "under", "again", "once", "only", "own", "same", "such", "can", "will", "would", "could", "should",
    "might", "must", "shall", "was", "were", "are", "been", "being", "have", "has", "had", "does", "did",
    "doing", "got", "get", "gets", "let", "lets", "yeah", "yea", "ooh", "ohh", "uh", "huh", "hey", "nah",
    "gonna", "wanna", "gotta", "aint", "dont", "cant", "wont", "didnt", "isnt", "wasnt", "im", "ive",
    "ill", "youre", "theyre", "thats", "whats", "like", "know", "say", "said", "tell", "make", "made",
    "way", "thing", "things", "something", "nothing", "everything", "anything", "one", "out", "off",
]

/// An icon that springs in next to its word, slightly wiggling. Sized like the word's text.
struct WordIconView: View {
    let symbol: String
    let size: CGFloat
    let color: Color
    @State private var arrived = false

    var body: some View {
        icon
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .scaleEffect(arrived ? 1 : 0.2)
            .rotationEffect(.degrees(arrived ? 0 : -14))
            .opacity(arrived ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.25)) { arrived = true }
            }
    }

    @ViewBuilder private var icon: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: symbol).symbolEffect(.wiggle.byLayer, options: .speed(1.5), value: arrived)
        } else {
            Image(systemName: symbol)
        }
    }
}
