import Combine
import CoreAudio
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
    private let lyricsWindow = LyricsWindow()
    private let awake = DisplayAwake()
    private var subscriptions = Set<AnyCancellable>()

    @Published var lyrics: Lyrics?
    @Published var status = "Waiting for music"
    @Published var isLocked = false
    /// Extra delay for the current audio output; Bluetooth headphones play ~0.2 s late.
    @Published var outputDelay = 0.0

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
        outputDelay = outputIsBluetooth() ? 0.2 : 0  // headphones can change between songs
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

    func openLyricsWindow() {
        lyricsWindow.open(AnyView(ConstellationView(model: self, player: player)))
    }

    /// Shows the lock screen overlay only while lyrics exist, music plays, and the Mac is locked.
    private func refresh() {
        let show = lyrics != nil && player.isPlaying && isLocked
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

/// An ordinary resizable window for watching the lyrics while the Mac is unlocked.
@MainActor
final class LyricsWindow {
    private var window: NSWindow?

    func open(_ content: AnyView) {
        if window == nil {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            newWindow.title = "Lilt"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.backgroundColor = .black
            newWindow.isReleasedWhenClosed = false  // so the menu can open it again after closing
            newWindow.contentMinSize = NSSize(width: 480, height: 300)
            newWindow.contentView = NSHostingView(rootView: content)
            newWindow.center()
            newWindow.setFrameAutosaveName("LiltLyricsWindow")  // remembers size and position
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// True when the default output device is Bluetooth (AirPods and friends).
func outputIsBluetooth() -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
    else { return false }

    address.mSelector = kAudioDevicePropertyTransportType
    var transport = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
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
    @AppStorage("textColor") private var textHex = Theme.defaultText
    @AppStorage("highlightColor") private var highlightHex = Theme.defaultHighlight
    @AppStorage("secondaryColor") private var secondaryHex = Theme.defaultSecondary
    @AppStorage("autoSyncColors") private var autoSync = false
    @AppStorage("lyricFont") private var fontChoice = LyricFont.sfPro.rawValue
    @AppStorage("lyricsDelay") private var delay = 0.0

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
            Text("Color").font(.caption).foregroundStyle(.secondary)
            Toggle("Auto Sync from album", isOn: $autoSync)
            ColorPicker("Lyric text", selection: hexBinding($textHex))
            ColorPicker("Highlight", selection: hexBinding($highlightHex)).disabled(autoSync)
            ColorPicker("Secondary text", selection: hexBinding($secondaryHex))
            Button("Reset colors") {
                textHex = Theme.defaultText
                highlightHex = Theme.defaultHighlight
                secondaryHex = Theme.defaultSecondary
            }

            Picker("Font", selection: $fontChoice) {
                ForEach(LyricFont.allCases) { choice in
                    Text(choice.rawValue).tag(choice.rawValue)
                }
            }

            Divider()
            Button("Open lyrics window") { model.openLyricsWindow() }
            HStack {
                Text("Lyrics delay")
                Slider(value: $delay, in: -0.5...1.0, step: 0.05)
                Text(String(format: "%+.2f s", delay)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            if model.outputDelay > 0 {
                Text("Bluetooth output: +0.20 s added automatically").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            SecureField("Cider app token", text: $token)
            Text("Make one in Cider → Settings → Connectivity").font(.caption2).foregroundStyle(.secondary)

            Divider()
            Button("Quit Lilt") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 270)
    }
}
