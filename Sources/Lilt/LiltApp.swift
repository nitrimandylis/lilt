import Combine
import IOKit.pwr_mgt
import SkyLightWindow
import SwiftUI

@main
struct LiltApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--preview"), flag + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { renderPreview(to: CommandLine.arguments[flag + 1]) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Lilt", systemImage: "sparkles") {
            MenuView(model: model, player: model.player)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let player: PlayerMonitor
    private let store: LyricsStore
    private let overlay = OverlayWindow()
    private let awake = DisplayAwake()
    private var subscriptions = Set<AnyCancellable>()

    @Published var lyrics: Lyrics?
    @Published var status = "Waiting for music"
    @Published var isLocked = false
    @Published var showWhenUnlocked = UserDefaults.standard.bool(forKey: "showWhenUnlocked") {
        didSet {
            UserDefaults.standard.set(showWhenUnlocked, forKey: "showWhenUnlocked")
            refresh()
        }
    }

    init() {
        let cider = CiderClient()
        player = PlayerMonitor(cider: cider)
        store = LyricsStore(cider: cider)

        // receive(on:) waits until the new value is stored before we read it.
        player.$track.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] track in self?.trackChanged(track) }
            .store(in: &subscriptions)
        player.$isPlaying.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        }

        player.start()
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        refresh()
    }

    private func trackChanged(_ track: Track?) {
        lyrics = nil
        refresh()
        guard let track else {
            status = "Waiting for music"
            return
        }
        status = "Looking up lyrics…"
        Task {
            let found = await store.lyrics(for: track)
            guard player.track == track else { return }  // the song changed while we waited
            lyrics = found
            if let found {
                status = found.wordTimed ? "Word-timed lyrics" : "Line-timed lyrics, word times estimated"
            } else {
                status = "No lyrics found (is Cider open with a token?)"
            }
            refresh()
        }
    }

    /// Shows the overlay only while lyrics exist, music plays, and the Mac is locked (or the user wants it always).
    private func refresh() {
        let show = lyrics != nil && player.isPlaying && (isLocked || showWhenUnlocked)
        if show {
            overlay.show(AnyView(ConstellationView(model: self, player: player)))
        } else {
            overlay.hide()
        }
        awake.set(show)
    }
}

/// A full-screen, click-through window placed above the lock screen.
@MainActor
final class OverlayWindow {
    private var panel: NSPanel?

    func show(_ content: AnyView) {
        guard let screen = NSScreen.main else { return }
        if panel == nil {
            // A non-activating panel never steals keyboard focus from the app you are using.
            let newPanel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.ignoresMouseEvents = true
            newPanel.canBecomeVisibleWithoutLogin = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            newPanel.level = .screenSaver
            newPanel.contentView = NSHostingView(rootView: content)
            panel = newPanel
        }
        guard let panel, !panel.isVisible else { return }
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        // Needs a window number, so only after the window is on screen.
        SkyLightOperator.shared.delegateWindow(panel)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// Keeps the display from sleeping while lyrics are on screen.
final class DisplayAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func set(_ on: Bool) {
        if on && !held {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Lilt is showing lyrics" as CFString,
                &assertion)
            held = result == kIOReturnSuccess
        } else if !on && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerMonitor
    // ponytail: token sits in UserDefaults in plain text, move to Keychain if that ever matters.
    @AppStorage("ciderToken") private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track = player.track {
                Text(track.title).font(.headline)
                Text("\(track.artist) · \(track.source.rawValue)").foregroundStyle(.secondary)
            } else {
                Text("Nothing playing").font(.headline)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle("Show when unlocked", isOn: $model.showWhenUnlocked)
            SecureField("Cider app token", text: $token)
            Text("Make one in Cider → Settings → Connectivity").font(.caption2).foregroundStyle(.secondary)

            Divider()
            Button("Quit Lilt") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 270)
    }
}
