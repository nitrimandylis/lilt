import AppKit
import Foundation

enum PlayerSource: String {
    case cider = "Cider"
    case music = "Music"
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var catalogId: String?  // Apple Music catalog id, when the player hands one over
    var source: PlayerSource
}

struct PlaybackState {
    var track: Track
    var position: Double  // seconds into the song
    var isPlaying: Bool
}

/// Talks to Cider's local REST API on port 10767.
struct CiderClient {
    let base = "http://127.0.0.1:10767"

    // The user pastes this into the menu. Cider makes it in Settings → Connectivity.
    var token: String {
        UserDefaults.standard.string(forKey: "ciderToken") ?? ""
    }

    func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue(token, forHTTPHeaderField: "apptoken")
        return await send(request)
    }

    func post(_ path: String, body: [String: Any], timeout: Double) async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "apptoken")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(request)
    }

    /// Runs an Apple Music API call through Cider, using Nick's subscription.
    func amapi(_ path: String) async -> [String: Any]? {
        return await post("/api/v1/amapi/run-v3", body: ["path": path], timeout: 10)
    }

    private func send(_ request: URLRequest) async -> [String: Any]? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil  // Cider closed, or the token is wrong
        }
    }

    /// Just the playback position, for the fast poll.
    func currentTime() async -> Double? {
        let time = await get("/api/v2/playback/time")?["data"] as? [String: Any]
        return time?["currentTime"] as? Double
    }

    func nowPlaying() async -> PlaybackState? {
        guard let nowPlaying = await get("/api/v1/playback/now-playing"),
              let info = nowPlaying["info"] as? [String: Any],
              let title = info["name"] as? String
        else { return nil }

        // v2 routes wrap their answer in {data: ...}, v1 routes do not.
        let time = await get("/api/v2/playback/time")?["data"] as? [String: Any]
        let state = await get("/api/v2/playback/state")?["data"] as? [String: Any]

        let playParams = info["playParams"] as? [String: Any]
        var catalogId: String? = nil
        if let id = playParams?["catalogId"] as? String {
            catalogId = id
        } else if let id = playParams?["id"] as? String, id.allSatisfy({ $0.isNumber }) {
            catalogId = id  // library ids start with "i.", catalog ids are all digits
        }
        let track = Track(
            title: title,
            artist: info["artistName"] as? String ?? "",
            album: info["albumName"] as? String ?? "",
            catalogId: catalogId,
            source: .cider
        )
        return PlaybackState(
            track: track,
            position: time?["currentTime"] as? Double ?? 0,
            isPlaying: state?["state"] as? String == "playing"
        )
    }
}

/// Reads Music.app over AppleScript. Only asks when Music is already open, so it never launches it.
enum MusicApp {
    static let script = NSAppleScript(source: """
        if application "Music" is running then
            tell application "Music"
                if player state is stopped then return ""
                set t to current track
                return (name of t) & tab & (artist of t) & tab & (album of t) & tab & (player position as text) & tab & (player state as text)
            end tell
        end if
        return ""
        """)

    static func nowPlaying() -> PlaybackState? {
        var error: NSDictionary?
        guard let output = script?.executeAndReturnError(&error).stringValue else { return nil }
        let parts = output.components(separatedBy: "\t")
        guard parts.count == 5 else { return nil }

        // AppleScript formats the position with the system locale, so "12,5" can happen.
        let position = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
        let track = Track(title: parts[0], artist: parts[1], album: parts[2],
                          catalogId: nil, source: .music)
        return PlaybackState(track: track, position: position, isPlaying: parts[4] == "playing")
    }
}

/// Polls the players and predicts the position between polls.
///
/// Cider only refreshes its reported position about once a second, so a reading can be up to
/// a second old. A reading is only fresh at the moment it changes, so we poll the position
/// ten times a second and re-sync the clock on those changes, never on a stale value.
@MainActor
final class PlayerMonitor: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false

    private let cider: CiderClient
    private var anchorPosition: Double = 0
    private var anchorDate = Date()
    private var lastReported: Double = -1  // the last position value Cider sent

    init(cider: CiderClient) {
        self.cider = cider
    }

    func start() {
        Task {
            var tick = 0
            while true {
                if tick % 5 == 0 {
                    await poll()  // full check: which player, which track, playing or not
                } else if track?.source == .cider && isPlaying, let time = await cider.currentTime() {
                    absorb(time, source: .cider)  // quick check: just the position
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Song position at a given moment. The lyrics animation calls this every frame.
    func position(at date: Date) -> Double {
        if isPlaying {
            return anchorPosition + date.timeIntervalSince(anchorDate)
        }
        return anchorPosition
    }

    private func poll() async {
        // Prefer whichever player is actually playing, Cider first.
        let ciderState = await cider.nowPlaying()
        if let state = ciderState, state.isPlaying {
            apply(state)
            return
        }
        // ponytail: AppleScript runs on the main thread (~10-50 ms), move it off if the menu ever stutters.
        let musicState = MusicApp.nowPlaying()
        if let state = musicState, state.isPlaying {
            apply(state)
            return
        }
        apply(ciderState ?? musicState)
    }

    private func apply(_ state: PlaybackState?) {
        guard let state else {
            if track != nil { track = nil }
            if isPlaying { isPlaying = false }
            return
        }

        let changed = state.track != track || state.isPlaying != isPlaying
        if state.track != track { track = state.track }
        if state.isPlaying != isPlaying { isPlaying = state.isPlaying }
        if changed {
            setAnchor(state.position)
            lastReported = state.position
            return
        }
        absorb(state.position, source: state.track.source)
    }

    /// Decides whether a reported position should move our clock.
    private func absorb(_ reported: Double, source: PlayerSource) {
        let fresh = reported != lastReported
        lastReported = reported
        let error = position(at: Date()) - reported

        if abs(error) > 1.5 {
            setAnchor(reported)  // a seek, or the clock drifted badly
        } else if source == .cider && fresh {
            // Cider just ticked, so this value is at most one poll (0.1 s) old; split the difference.
            setAnchor(reported + 0.05)
        } else if source == .music && abs(error) > 0.3 {
            setAnchor(reported)  // Music.app reports an exact position every time
        }
    }

    private func setAnchor(_ position: Double) {
        anchorPosition = position
        anchorDate = Date()
    }
}
