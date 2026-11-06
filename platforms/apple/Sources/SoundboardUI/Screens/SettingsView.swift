import SwiftUI
import SoundboardAudio
#if canImport(CoreMIDI)
import CoreMIDI
#endif

// MARK: - Building blocks

/// Which platforms a setting applies to. Shown as a small badge next to the setting.
enum PlatformScope {
    case all, iOS, macOS
    var label: String? {
        switch self {
        case .all: nil
        case .iOS: "IPHONE · IPAD"
        case .macOS: "MAC"
        }
    }
    static var current: PlatformScope {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }
}

/// A titled card of rows separated by hairlines, with an optional explanation under it.
@MainActor
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.obsidian) private var t

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Eyebrow(title).padding(.horizontal, 4) }
            VStack(spacing: 0) { content }
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
            if let footer {
                Text(footer).font(t.ui(12)).foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row: label (with optional detail and platform badge) on the left, a control on the right.
@MainActor
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var scope: PlatformScope = .all
    var divider = true
    @ViewBuilder var trailing: Trailing
    @Environment(\.obsidian) private var t

    init(_ title: String, detail: String? = nil, scope: PlatformScope = .all, divider: Bool = true,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.scope = scope
        self.divider = divider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(t.ui(14)).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
                    if let badge = scope.label { PlatformBadge(text: badge) }
                }
                if let detail {
                    Text(detail).font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .overlay(alignment: .top) { if divider { Rectangle().fill(t.border).frame(height: 1) } }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, scope: PlatformScope = .all, divider: Bool = true) {
        self.init(title, detail: detail, scope: scope, divider: divider) { EmptyView() }
    }
}

@MainActor
struct PlatformBadge: View {
    let text: String
    @Environment(\.obsidian) private var t
    var body: some View {
        Text(text).font(t.mono(9, .medium)).tracking(0.8)
            .foregroundStyle(t.textMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.border, lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Only on \(text.lowercased())")
    }
}

/// A trailing value in muted mono, truncated from the middle so ends stay readable.
@MainActor
struct ValueText: View {
    let text: String
    @Environment(\.obsidian) private var t
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(t.mono(12)).foregroundStyle(t.textSecondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 200, alignment: .trailing)
    }
}

@MainActor
struct SettingsToggle: View {
    let title: String
    var detail: String?
    var scope: PlatformScope = .all
    var divider = true
    @Binding var isOn: Bool
    @Environment(\.obsidian) private var t

    var body: some View {
        SettingsRow(title, detail: detail, scope: scope, divider: divider) {
            Toggle(title, isOn: $isOn).labelsHidden().tint(t.primary)
        }
    }
}

/// A full-width choice under a label.
@MainActor
struct SettingsChoice<T: Hashable>: View {
    let title: String
    var detail: String?
    var divider = true
    let options: [(T, String)]
    @Binding var selection: T
    @Environment(\.obsidian) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(t.ui(14)).foregroundStyle(t.text)
            Segmented(options, selection: $selection, mono: false)
            if let detail { Text(detail).font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if divider { Rectangle().fill(t.border).frame(height: 1) } }
    }
}

@MainActor
struct SettingsLink<Destination: View>: View {
    let title: String
    let value: String
    let systemImage: String
    @ViewBuilder var destination: Destination
    @Environment(\.obsidian) private var t

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 22).foregroundStyle(t.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(t.ui(15, .medium)).foregroundStyle(t.text)
                    Text(value).font(t.ui(12)).foregroundStyle(t.textMuted).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").foregroundStyle(t.textMuted)
            }
            .padding(12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A destructive or neutral action row with a confirmation.
@MainActor
struct SettingsAction: View {
    let title: String
    var detail: String?
    var destructive = false
    var divider = true
    var disabled = false
    let confirmTitle: String
    let confirmMessage: String
    let action: () -> Void
    @State private var confirming = false
    @Environment(\.obsidian) private var t

    var body: some View {
        Button { confirming = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(t.ui(14, .medium)).foregroundStyle(disabled ? t.textMuted : (destructive ? t.error : t.text))
                if let detail { Text(detail).font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .overlay(alignment: .top) { if divider { Rectangle().fill(t.border).frame(height: 1) } }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(title, role: destructive ? .destructive : nil, action: action)
        } message: { Text(confirmMessage) }
    }
}

/// Every settings page shares the same scroll, width and padding.
@MainActor
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.obsidian) private var t

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(t.pad)
                .frame(maxWidth: .infinity)
        }
        .background(t.background)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Settings home

@MainActor
struct SettingsView: View {
    @Bindable var store: AppearanceStore
    @Bindable var session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage("Settings") {
            if let e = session.errorMessage {
                NoticeBar(text: e) {}
            }
            SettingsGroup {
                SettingsLink(title: "Audio & routing", value: routeSummary, systemImage: "hifispeaker.and.headphones") {
                    AudioSettingsView(session: session)
                }
                divider
                SettingsLink(title: "Mixing", value: mixingSummary, systemImage: "slider.vertical.3") {
                    MixingSettingsView(session: session)
                }
                divider
                SettingsLink(title: "Controllers", value: "MIDI devices and DJ interfaces", systemImage: "pianokeys") {
                    ControllerSettingsView(session: session)
                }
            }
            SettingsGroup {
                SettingsLink(title: "Library", value: "\(session.library.tracks.count) tracks · \(session.library.playlists.count) playlists", systemImage: "music.note.list") {
                    LibrarySettingsView(session: session)
                }
                divider
                SettingsLink(title: "Sessions", value: session.sessions.current?.name ?? "—", systemImage: "square.stack") {
                    SessionSettingsView(session: session)
                }
            }
            SettingsGroup {
                SettingsLink(title: "Appearance", value: store.appearance.theme.title + " · " + store.appearance.accent.title, systemImage: "paintpalette") {
                    AppearanceView(store: store, session: session)
                }
            }
            SettingsGroup {
                SettingsLink(title: "Reset", value: "Mixer, audio, settings", systemImage: "arrow.counterclockwise") {
                    ResetSettingsView(store: store, session: session)
                }
                divider
                SettingsLink(title: "About", value: AboutView.versionText, systemImage: "info.circle") {
                    AboutView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var divider: some View { Rectangle().fill(t.border).frame(height: 1) }

    private var routeSummary: String {
        let master = session.plan?.masterPort?.name ?? "No output"
        return session.cueAvailable ? "\(master) · cue on \(session.plan?.cuePort?.name ?? master)" : "\(master) · no headphone cue"
    }

    private var mixingSummary: String {
        let m = session.preferences.prefs.mixing
        return "\(m.transition.title) · \(m.transitionBeats) beats · \(m.quantize ? "quantised" : "free")"
    }
}

// MARK: - Audio & routing

@MainActor
struct AudioSettingsView: View {
    @Bindable var session: DJSession
    @Environment(\.obsidian) private var t
    private var prefs: Binding<AudioPrefs> { Binding(get: { session.preferences.prefs.audio }, set: { session.preferences.prefs.audio = $0 }) }

    var body: some View {
        SettingsPage("Audio & routing") {
            SettingsGroup("Where the sound goes", footer: topologyText) {
                SettingsRow("Speakers (master)", divider: false) { ValueText(session.plan?.masterPort?.name ?? "—") }
                SettingsRow("Headphones (cue)") {
                    ValueText(session.cueAvailable ? (session.plan?.cuePort?.name ?? "Same output, right channel") : "Not available")
                }
                ForEach(Array(notices.enumerated()), id: \.offset) { _, n in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(t.warning)
                        Text(n).font(t.ui(13)).foregroundStyle(t.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
                }
            }

            SettingsGroup("Outputs", footer: outputsFooter) {
                devicePicker("Master output", selection: prefs.masterOutputID, divider: false)
                devicePicker("Headphone output", selection: prefs.cueOutputID)
                SettingsToggle(title: "I'm using a splitter cable",
                               detail: "Master in the left ear of the cable, cue in the right. Both become mono.",
                               isOn: prefs.splitterCable)
                #if os(iOS)
                SettingsToggle(title: "Use two outputs at once", detail: "Multi-route: USB, HDMI or line-out for the speakers plus wired headphones.",
                               scope: .iOS, isOn: prefs.allowMultiRoute)
                #endif
            }

            SettingsGroup("Monitoring", footer: session.cueAvailable ? nil : "Connect headphones through a splitter cable, USB audio interface or DJ controller to monitor privately.") {
                VStack(alignment: .leading, spacing: 10) {
                    Fader("Cue and master blend", value: $session.cueMix, in: 0...1, leading: "CUE", trailing: "MASTER")
                    Fader("Headphone volume", value: $session.headphoneVolume, in: 0...1, leading: "PHONES")
                    Fader("Master volume", value: $session.masterVolume, in: 0...1, leading: "MASTER")
                }
                .padding(12)
                .disabled(!session.cueAvailable)
            }

            SettingsGroup("Latency", footer: "Smaller buffers respond faster to your hands but need more CPU. If you hear crackles, choose a larger buffer.") {
                SettingsChoice(title: "Buffer size", divider: false,
                               options: AudioPrefs.bufferChoices.map { ($0, $0 == 0 ? "Auto" : "\($0)") },
                               selection: prefs.bufferFrames)
                SettingsRow("In effect") { ValueText(latencyText) }
                SettingsChoice(title: "Master ceiling",
                               detail: "The limiter keeps the master below this level so it never clips.",
                               options: [(-0.1, "−0.1 dB"), (-0.3, "−0.3 dB"), (-1.0, "−1 dB"), (-3.0, "−3 dB")],
                               selection: prefs.limiterCeilingDb)
            }

            SettingsGroup {
                SettingsAction(title: "Reset audio configuration", detail: "Automatic outputs, default buffer and ceiling.",
                               destructive: true, divider: false, disabled: session.preferences.prefs.audio == AudioPrefs(),
                               confirmTitle: "Reset audio configuration?",
                               confirmMessage: "Outputs go back to automatic and the buffer and ceiling to their defaults. Audio restarts briefly.") {
                    session.preferences.resetAudio()
                }
            }
        }
    }

    @ViewBuilder private func devicePicker(_ title: String, selection: Binding<String?>, divider: Bool = true) -> some View {
        SettingsRow(title, divider: divider) {
            Picker(title, selection: selection) {
                Text("Automatic").tag(String?.none)
                ForEach(session.outputs, id: \.id) { port in
                    Text("\(port.name) · \(port.channels) ch").tag(Optional(port.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(t.textSecondary)
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private var outputsFooter: String {
        #if os(iOS)
        "iPhone and iPad route to what is connected. A phone alone cannot play the speaker and cue in Bluetooth headphones at the same time; that is an iOS limit."
        #else
        "On a Mac any two outputs can run together; the headphone output is kept in time with the master automatically."
        #endif
    }

    private var topologyText: String? {
        guard let plan = session.plan else { return nil }
        switch plan.topology {
        case .masterOnly: return "Everything plays on one output. Sync, Mix and the visual tools still work."
        case .splitMono: return "One stereo output carries the master on the left and the cue on the right."
        case .multiChannel: return "One multichannel interface: master and cue on separate outputs, one clock."
        case .separateCueDevice: return "Two devices: master and cue each on their own output, drift-corrected."
        }
    }

    private var latencyText: String {
        guard session.sampleRate > 0 else { return "—" }
        let ms = Double(session.measuredBufferFrames) / session.sampleRate * 1000
        let out = session.measuredOutputLatency * 1000
        return String(format: "%d frames · %.1f ms · output %.0f ms · %.0f kHz",
                      session.measuredBufferFrames, ms, out, session.sampleRate / 1000)
    }

    private var notices: [String] {
        (session.plan?.notices ?? []).map {
            switch $0 {
            case .cueNeedsHardware: "Private pre-listening needs a splitter cable, a USB audio interface or a DJ controller."
            case .wirelessMasterLatency(let ms): "Wireless speakers add about \(ms) ms; the waveform is shifted to match."
            case .wirelessCueLatency(let ms): "Wireless headphones add about \(ms) ms. Wired headphones are recommended for cueing."
            case .airPlayNotForLiveMixing: "AirPlay buffers for about two seconds: fine for playback, not for live mixing."
            case .cueSlowerThanMaster(let ms): "Your headphones are \(ms) ms behind the speakers."
            }
        }
    }
}

// MARK: - Mixing

@MainActor
struct MixingSettingsView: View {
    let session: DJSession
    private var m: Binding<MixingPrefs> { Binding(get: { session.preferences.prefs.mixing }, set: { session.preferences.prefs.mixing = $0 }) }

    var body: some View {
        SettingsPage("Mixing") {
            SettingsGroup("Mix button", footer: "Mix starts on the next phrase of the playing track, so the change lands where the music expects it.") {
                SettingsChoice(title: "Transition", divider: false, options: TransitionKind.allCases.map { ($0, $0.title) }, selection: m.transition)
                SettingsChoice(title: "Length", options: MixingPrefs.transitionBeatChoices.map { ($0, "\($0) beats") }, selection: m.transitionBeats)
                SettingsChoice(title: "Phrase", options: MixingPrefs.phraseChoices.map { ($0, "\($0) beats") }, selection: m.phraseBeats)
            }
            SettingsGroup("Decks") {
                SettingsToggle(title: "Quantise", detail: "Cue points, loops and pads snap to the beat.", divider: false, isOn: m.quantize)
                SettingsToggle(title: "Level-match tracks", detail: "Adjusts each track's gain from its measured loudness.", isOn: m.autoGain)
                SettingsToggle(title: "Start tracks on the first beat", isOn: m.loadAtFirstBeat)
                SettingsToggle(title: "Cue new tracks in the headphones", detail: "When the other deck is playing.", isOn: m.autoCueOnLoad)
            }
            SettingsGroup("Crossfader") {
                SettingsChoice(title: "Curve", detail: "Smooth for long blends, sharp for cuts and scratching.", divider: false,
                               options: [(0.0, "Smooth"), (0.5, "Medium"), (1.0, "Sharp")], selection: m.crossfaderCurve)
            }
        }
    }
}

// MARK: - Controllers

@MainActor
struct ControllerSettingsView: View {
    let session: DJSession
    @State private var midi: [String] = []
    @Environment(\.obsidian) private var t

    var body: some View {
        SettingsPage("Controllers") {
            SettingsGroup("Audio", footer: "A DJ controller or interface with four or more outputs gives you a separate headphone output automatically.") {
                let multi = session.outputs.filter { $0.channels >= 4 }
                if multi.isEmpty {
                    SettingsRow("No multichannel interface connected", divider: false)
                } else {
                    ForEach(Array(multi.enumerated()), id: \.element.id) { i, port in
                        SettingsRow(port.name, detail: "\(port.channels) outputs", divider: i > 0) {
                            if session.plan?.topology == .multiChannel && session.plan?.masterPort?.id == port.id {
                                Text("IN USE").font(t.mono(10, .medium)).foregroundStyle(t.success)
                            }
                        }
                    }
                }
            }
            SettingsGroup("MIDI", footer: "Class-compliant MIDI controllers are detected here. Mapping their jog wheels, pads and faders arrives with DJ Mode; until then they are not used.") {
                if midi.isEmpty {
                    SettingsRow("No MIDI controllers found", divider: false) {
                        Button("Refresh") { midi = MIDIDevices.sources() }.buttonStyle(ObsidianButtonStyle())
                    }
                } else {
                    ForEach(Array(midi.enumerated()), id: \.offset) { i, name in SettingsRow(name, divider: i > 0) }
                }
            }
        }
        .onAppear { midi = MIDIDevices.sources() }
    }
}

enum MIDIDevices {
    /// Display names of connected MIDI sources (controllers that send to the app).
    static func sources() -> [String] {
        #if canImport(CoreMIDI)
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let endpoint = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name else { return nil }
            return name.takeRetainedValue() as String
        }
        #else
        []
        #endif
    }
}

// MARK: - Library

@MainActor
struct LibrarySettingsView: View {
    let session: DJSession
    @State private var bytes: Int64 = 0
    private var lib: Binding<LibraryPrefs> { Binding(get: { session.preferences.prefs.library }, set: { session.preferences.prefs.library = $0 }) }
    private var library: LibraryStore { session.library }

    var body: some View {
        SettingsPage("Library") {
            SettingsGroup("Importing", footer: importFooter) {
                #if os(macOS)
                SettingsToggle(title: "Copy files into the library", detail: "Keeps tracks playable if you move or delete the originals. Uses disk space.",
                               scope: .macOS, divider: false, isOn: lib.copyIntoLibrary)
                #else
                SettingsRow("Imported files are copied into Soundboard", scope: .iOS, divider: false)
                #endif
                SettingsRow("Formats") { ValueText(AudioFormats.supportedExtensions.map { $0.uppercased() }.joined(separator: " ")) }
            }
            SettingsGroup("Storage") {
                SettingsRow("Tracks", divider: false) { ValueText("\(library.tracks.count)") }
                SettingsRow("Copied audio") { ValueText(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }
            SettingsGroup("Maintenance") {
                SettingsAction(title: "Analyse all tracks again", detail: "Re-detects BPM, beat grid, key and loudness. Cue points are kept.",
                               divider: false, disabled: library.tracks.isEmpty,
                               confirmTitle: "Analyse every track again?",
                               confirmMessage: "This runs in the background and can take a few minutes for a large library.") {
                    library.reanalyseAll()
                }
                let missing = library.tracks.filter { $0.state == .missing }.count
                SettingsAction(title: "Remove missing tracks", detail: missing == 0 ? "None are missing." : "\(missing) track\(missing == 1 ? "" : "s") can't be found.",
                               destructive: true, disabled: missing == 0,
                               confirmTitle: "Remove \(missing) missing tracks?",
                               confirmMessage: "They are removed from the library, playlists and queues.") {
                    library.removeMissing()
                }
                SettingsAction(title: "Remove all tracks", detail: "Empties the library and every playlist.",
                               destructive: true, disabled: library.tracks.isEmpty,
                               confirmTitle: "Remove every track?",
                               confirmMessage: "All tracks, cue points and playlists contents are removed and copied audio is deleted. Sessions stay, with empty decks. This can't be undone.") {
                    library.removeAll()
                    bytes = Storage.mediaBytes()
                }
            }
        }
        .task { bytes = await Task.detached { Storage.mediaBytes() }.value }
    }

    private var importFooter: String {
        #if os(iOS)
        "Files from the Files app are only lent to Soundboard, so each one is copied in. iCloud files are downloaded first."
        #else
        "With copying off, Soundboard remembers where each file is and asks macOS for access when it loads."
        #endif
    }
}

// MARK: - Sessions

@MainActor
struct SessionSettingsView: View {
    let session: DJSession
    private var s: Binding<SessionPrefs> { Binding(get: { session.preferences.prefs.session }, set: { session.preferences.prefs.session = $0 }) }

    var body: some View {
        SettingsPage("Sessions") {
            SettingsGroup("Starting up", footer: "Restored decks are paused at the position they were saved. Sessions save automatically every few seconds.") {
                SettingsToggle(title: "Reopen the last session", divider: false, isOn: s.restoreLastSession)
                #if os(iOS)
                SettingsToggle(title: "Keep the screen on", detail: "While Soundboard is open.", scope: .iOS, isOn: s.keepScreenOn)
                #endif
            }
            SessionsList(session: session)
        }
    }
}

/// Named sessions: open, rename, duplicate, delete, new. Also shown from the session chip.
@MainActor
struct SessionsList: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    @State private var naming: Naming?
    @State private var draft = ""
    @State private var deleting: SessionInfo?

    enum Naming: Equatable { case new, duplicate, rename(UUID) }

    var body: some View {
        SettingsGroup("Saved sessions", footer: "The library and playlists are shared by every session. A session keeps its decks, mixer, queue and library view.") {
            let items = session.sessions.sessions.sorted { $0.modified > $1.modified }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, info in row(info, divider: i > 0) }
            HStack(spacing: 8) {
                Button("NEW SESSION") { draft = ""; naming = .new }.buttonStyle(ObsidianButtonStyle(prominent: true))
                Button("DUPLICATE") { draft = (session.sessions.current?.name ?? "Session") + " copy"; naming = .duplicate }
                    .buttonStyle(ObsidianButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
        }
        .alert(alertTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") { commit() }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                if let id = deleting?.id { Task { await session.deleteSession(id) } }
                deleting = nil
            }
        } message: { Text("Its decks, mixer and queue are deleted. Tracks stay in the library.") }
    }

    private func row(_ info: SessionInfo, divider: Bool) -> some View {
        let current = info.id == session.sessions.currentID
        return HStack(spacing: 10) {
            Image(systemName: current ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(current ? t.primary : t.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(t.ui(14, current ? .semibold : .regular)).foregroundStyle(t.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(info.modified.formatted(.relative(presentation: .named))).font(t.ui(12)).foregroundStyle(t.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if !current { Button { Task { await session.switchSession(to: info.id) } } label: { Label("Open", systemImage: "arrow.right.circle") } }
                Button { draft = info.name; naming = .rename(info.id) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { deleting = info } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()).foregroundStyle(t.textSecondary)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .accessibilityLabel("Options for \(info.name)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if !current { Task { await session.switchSession(to: info.id) } } }
        .overlay(alignment: .top) { if divider { Rectangle().fill(t.border).frame(height: 1) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : .isButton)
    }

    private var alertTitle: String {
        switch naming {
        case .new: "New session"
        case .duplicate: "Duplicate session"
        case .rename: "Rename session"
        case nil: ""
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch naming {
        case .new: Task { await session.newSession(named: name.isEmpty ? "Session" : name) }
        case .duplicate: session.duplicateSession(named: name.isEmpty ? "Session copy" : name)
        case .rename(let id): session.sessions.rename(id, to: name)
        case nil: break
        }
        naming = nil
    }
}

/// The session switcher sheet opened from the session chip.
@MainActor
struct SessionsSheet: View {
    let session: DJSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.obsidian) private var t

    var body: some View {
        SettingsPage("Sessions") {
            SessionsList(session: session)
            SettingsGroup {
                SettingsAction(title: "Clear this session", detail: "Ejects both decks, empties the queue and resets the mixer.",
                               destructive: true, divider: false,
                               confirmTitle: "Clear “\(session.sessions.current?.name ?? "")”?",
                               confirmMessage: "The library and other sessions are not affected.") {
                    Task { await session.clearSession() }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

// MARK: - Reset

@MainActor
struct ResetSettingsView: View {
    let store: AppearanceStore
    let session: DJSession

    var body: some View {
        SettingsPage("Reset") {
            SettingsGroup(footer: "None of these touch your library, playlists or saved sessions.") {
                SettingsAction(title: "Reset mixer", detail: "EQ, trim and filter to centre; channel faders up; crossfader to the deck on air.",
                               divider: false, disabled: session.mixerIsNeutral,
                               confirmTitle: "Reset the mixer?", confirmMessage: "Tracks keep playing.") {
                    session.resetMixer()
                }
                SettingsAction(title: "Reset audio configuration", detail: "Automatic outputs, default buffer and ceiling.",
                               destructive: true, disabled: session.preferences.prefs.audio == AudioPrefs(),
                               confirmTitle: "Reset audio configuration?", confirmMessage: "Audio restarts briefly.") {
                    session.preferences.resetAudio()
                }
                SettingsAction(title: "Reset all settings", detail: "Audio, mixing, library, session and appearance settings return to their defaults.",
                               destructive: true,
                               confirmTitle: "Reset all settings?", confirmMessage: "Your library and sessions are kept. Audio restarts briefly.") {
                    session.preferences.resetAll()
                    store.appearance = Appearance()
                }
            }
        }
    }
}

// MARK: - About

@MainActor
struct AboutView: View {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        SettingsPage("About") {
            SettingsGroup {
                SettingsRow("Soundboard", divider: false) { ValueText(Self.versionText) }
                SettingsRow("Engine") { ValueText("Soundboard Engine · C++17") }
                SettingsRow("Fonts") { ValueText("Geist · Geist Mono (SIL OFL 1.1)") }
            }
        }
    }
}
