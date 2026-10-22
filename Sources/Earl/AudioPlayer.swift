import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Maths

/// The pure parts of playback, kept apart so they can be tested without audio hardware.
enum PlaybackMath {
    /// Playback starts a little before a turn so its first word isn't clipped.
    static let lead: Double = 1
    static let rates: [Float] = [1, 1.25, 1.5, 2]

    static func startTime(forTurnAt start: Double) -> Double { max(0, start - lead) }

    /// The frame to start a file at, clamped to the file.
    static func frame(at seconds: Double, sampleRate: Double, length: AVAudioFramePosition) -> AVAudioFramePosition {
        guard seconds.isFinite, sampleRate > 0 else { return 0 }
        return min(max(0, AVAudioFramePosition((seconds * sampleRate).rounded())), max(0, length))
    }

    /// What the listener hears now, in seconds of the meeting.
    ///
    /// The player node counts frames of the file (the time-pitch unit downstream
    /// pulls `rate` times as many), so its clock is already media time. What it
    /// rendered reaches the speakers `latency` wall seconds later, which is
    /// `latency * rate` seconds of the meeting.
    static func position(offset: Double, sampleTime: AVAudioFramePosition, sampleRate: Double,
                         latency: Double = 0, rate: Float = 1) -> Double {
        guard sampleRate > 0 else { return offset }
        let rendered = Double(max(0, sampleTime)) / sampleRate
        return offset + max(0, rendered - latency * Double(rate))
    }

    /// Index of the turn playing at `time`: the last one that has started.
    /// `starts` must be sorted.
    static func turnIndex(starts: [Double], at time: Double) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    static func rateLabel(_ rate: Float) -> String {
        (rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%g", rate)) + "×"
    }
}

// MARK: - Player

/// Plays a meeting's two 16 kHz tracks mixed, in sync, at an adjustable speed.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTurnID: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var rate: Float = 1
    /// Whether the transcript scrolls along. Paused when the user scrolls.
    @Published var isFollowing = true

    /// The raw 48 kHz files only exist before transcription; these are the ones to play.
    nonisolated static let trackNames = ["system-16k.wav", "mic-16k.wav"]

    nonisolated static func canPlay(_ meeting: Meeting) -> Bool {
        meeting.files.contains { trackNames.contains($0.name) }
    }

    /// The loaded player, so recording can silence it (playback would leak into the capture).
    private static weak var active: MeetingPlayer?
    static func stopAll() { active?.unload() }

    /// The current turn of an optional player, for `onReceive`.
    static func currentTurn(of player: MeetingPlayer?) -> AnyPublisher<String?, Never> {
        player?.$currentTurnID.removeDuplicates().eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    private struct Track {
        let file: AVAudioFile
        let node: AVAudioPlayerNode
    }

    // Created on load, so the view can make players cheaply.
    private var engine: AVAudioEngine?
    private var timePitch: AVAudioUnitTimePitch?
    private var tracks: [Track] = []
    private var meetingID: String?
    private var turnStarts: [Double] = []
    private var turnIDs: [String] = []
    /// Meeting time where the current schedule starts; the node's clock counts from here.
    private var offset: Double = 0
    private var timer: Timer?
    private var configObserver: NSObjectProtocol?
    /// W-1: where a who's-who sample stops.
    private var stopAt: Double?

    func load(meeting: Meeting) {
        if isLoaded, meetingID == meeting.id { return }
        unload()
        let files = Self.trackNames.compactMap { name -> AVAudioFile? in
            let url = meeting.folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }
        .filter { $0.length > 0 }
        guard !files.isEmpty else { return }

        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(mixer)
        engine.attach(timePitch)
        for file in files {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixer, format: file.processingFormat)
            tracks.append(Track(file: file, node: node))
        }
        engine.connect(mixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.rate = rate
        engine.prepare()

        // A new output device stops the engine; pick up where we were.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }

        self.engine = engine
        self.timePitch = timePitch
        meetingID = meeting.id
        let turns = meeting.turns.sorted { $0.start < $1.start }
        turnStarts = turns.map(\.start)
        turnIDs = turns.map(\.id)
        // TrackWriter pads leading silence, so both tracks start aligned; the longer one sets the length.
        duration = files.map { Double($0.length) / $0.processingFormat.sampleRate }.max() ?? 0
        offset = 0
        setTime(0)
        isLoaded = true
        Self.active = self
    }

    func unload() {
        stopTimer()
        stopNodes()
        engine?.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = nil
        timePitch = nil
        tracks = []
        meetingID = nil
        turnStarts = []
        turnIDs = []
        offset = 0
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        currentTurnID = nil
        if Self.active === self { Self.active = nil }
    }

    /// Plays from just before a turn, loading the meeting if needed.
    func play(turn: Turn, in meeting: Meeting) {
        load(meeting: meeting)
        isFollowing = true
        play(from: PlaybackMath.startTime(forTurnAt: turn.start))
    }

    /// W-1: plays `seconds` of a turn from its very start, then pauses: a
    /// sample of one voice, for who's who.
    func playClip(_ turn: Turn, seconds: Double, in meeting: Meeting) {
        load(meeting: meeting)
        isFollowing = true
        play(from: turn.start)
        stopAt = turn.start + seconds
    }

    /// Plays from `seconds`, or from where it was paused.
    func play(from seconds: Double? = nil) {
        stopAt = nil // W-1
        guard let engine, !tracks.isEmpty else { return }
        var start = min(max(0, seconds ?? currentTime), duration)
        if seconds == nil, start >= duration - 0.05 { start = 0 } // play again from the top
        stopNodes()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            unload()
            return
        }
        // Both tracks start from the same frame at the same host time, so the
        // mic never drifts against the call audio.
        for track in tracks {
            let file = track.file
            let first = PlaybackMath.frame(at: start, sampleRate: file.processingFormat.sampleRate, length: file.length)
            let count = file.length - first
            if count > 0 {
                track.node.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil)
            }
        }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        for track in tracks { track.node.play(at: when) }
        offset = start
        setTime(start)
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        let time = position()
        stopNodes()
        engine?.pause()
        isPlaying = false
        stopTimer()
        setTime(time)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let time = min(max(0, seconds), duration)
        if isPlaying { play(from: time) } else { setTime(time) }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        timePitch?.rate = rate
    }

    // MARK: Position

    private func position() -> Double {
        // The longest track keeps playing to the end, so its clock is the reference.
        guard isPlaying, let engine,
              let reference = tracks.max(by: { $0.file.length < $1.file.length })?.node,
              let nodeTime = reference.lastRenderTime,
              let playerTime = reference.playerTime(forNodeTime: nodeTime) else { return currentTime }
        let latency = (timePitch?.latency ?? 0) + engine.outputNode.presentationLatency
        let time = PlaybackMath.position(offset: offset, sampleTime: playerTime.sampleTime,
                                         sampleRate: playerTime.sampleRate, latency: latency, rate: rate)
        return min(duration, time)
    }

    private func tick() {
        let time = position()
        if let stopAt, time >= stopAt { // W-1: the end of a who's-who sample
            self.stopAt = nil
            pause()
            return
        }
        if time >= duration {
            stopNodes()
            engine?.pause()
            isPlaying = false
            stopTimer()
        }
        setTime(time)
    }

    private func setTime(_ time: Double) {
        if abs(time - currentTime) > 0.001 { currentTime = time }
        let id = PlaybackMath.turnIndex(starts: turnStarts, at: time).map { turnIDs[$0] }
        if id != currentTurnID { currentTurnID = id }
    }

    private func configurationChanged() {
        guard isLoaded else { return }
        let wasPlaying = isPlaying
        let time = currentTime
        stopNodes()
        isPlaying = false
        stopTimer()
        if wasPlaying { play(from: time) }
    }

    private func stopNodes() {
        for track in tracks { track.node.stop() }
    }

    // About 10 updates a second: enough for the clock and the highlight,
    // without publishing on every render.
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        // .common so it keeps ticking while menus are open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Meeting page hook

extension View {
    /// Adds the player bar, follow-along scrolling, the Space key and stopping
    /// rules to the conversation's scroll view (U-2).
    func transcriptPlayback(_ player: MeetingPlayer, meeting: Meeting, active: Bool, enabled: Bool,
                            showsBar: Bool = true) -> some View {
        modifier(TranscriptPlayback(player: player, meeting: meeting, active: active, enabled: enabled, showsBar: showsBar))
    }
}

private struct TranscriptPlayback: ViewModifier {
    @ObservedObject var player: MeetingPlayer
    let meeting: Meeting
    /// The conversation is showing.
    let active: Bool
    /// False while the meeting is being processed and its audio may be rewritten.
    let enabled: Bool
    /// There's a conversation to play (U-2: the bar is there before playing starts).
    let showsBar: Bool

    @State private var keys = SpaceKeyMonitor()

    private var playable: Bool { enabled && MeetingPlayer.canPlay(meeting) }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if active && showsBar && enabled {
                        if playable {
                            PlayerBar(player: player, meeting: meeting) {
                                player.isFollowing = true
                                scroll(proxy, to: player.currentTurnID)
                            }
                        } else {
                            NoAudioNote()
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in
                    // Programmatic scrolls are .animating; anything else is the user.
                    if player.isPlaying, phase == .interacting || phase == .tracking || phase == .decelerating {
                        player.isFollowing = false
                    }
                }
                .onChange(of: player.currentTurnID) { _, id in
                    if active && player.isPlaying && player.isFollowing { scroll(proxy, to: id) }
                }
                .onChange(of: active) { _, active in
                    if !active { player.pause() }
                }
                .onChange(of: playable) { _, playable in
                    // Processing started, or the audio was deleted.
                    if !playable { player.unload() }
                }
                .onChange(of: active && playable && showsBar, initial: true) { _, on in
                    on ? keys.start { player.toggle(meeting) } : keys.stop()
                }
                .onDisappear {
                    keys.stop()
                    player.unload()
                }
                .background(WindowAnchor(monitor: keys))
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
    }
}

extension MeetingPlayer {
    /// Play or pause, loading the meeting first if nothing is loaded (U-2:
    /// the bar shows before anything has played).
    func toggle(_ meeting: Meeting) {
        if !isLoaded {
            load(meeting: meeting)
            guard isLoaded else { return }
        }
        toggle()
    }
}

/// Space toggles playback in the meeting window, unless you're typing.
@MainActor
private final class SpaceKeyMonitor {
    weak var anchor: NSView?
    private var monitor: Any?

    func start(_ action: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard event.keyCode == 49, modifiers.isEmpty, !event.isARepeat,
                      let window = self?.anchor?.window, event.window === window else { return false }
                // The title and search fields edit through an NSTextView.
                if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
                action()
                return true
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Lets the Space monitor know which window the player lives in.
private struct WindowAnchor: NSViewRepresentable {
    let monitor: SpaceKeyMonitor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        monitor.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        monitor.anchor = view
    }
}

// MARK: - Who speaks when

/// The player bar's waveform: one bar per stretch of speech, as long as it
/// lasted and coloured by who spoke (U-2, The Voice Colour Rule).
enum VoiceTimeline {
    struct Segment: Equatable {
        var start: Double
        var end: Double
        var voice: SpeakerVoice
        /// 0...1, a varied height so the bar reads as a waveform.
        var height: Double
    }

    /// Turns in time order; neighbours of one voice less than a second apart
    /// join up.
    static func segments(turns: [Turn], speakers: [Speaker]) -> [Segment] {
        let looks = SpeakerFaces.looks(for: speakers)
        var out: [Segment] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where turn.end > turn.start {
            let voice = VoicePalette.speakerVoice(for: turn, in: speakers, looks: looks)
            if var last = out.last, last.voice == voice, turn.start - last.end < 1 {
                last.end = max(last.end, turn.end)
                out[out.count - 1] = last
            } else {
                out.append(Segment(start: turn.start, end: turn.end, voice: voice, height: heights[out.count % heights.count]))
            }
        }
        return out
    }

    private static let heights: [Double] = [0.5, 0.75, 0.95, 0.55, 0.7, 0.85, 0.6, 0.45, 0.8, 0.65]
}

// MARK: - Views

/// At the bottom of the conversation: play/pause, the time, who speaks when
/// (click or drag to jump), the length and the speed.
struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer
    let meeting: Meeting
    var jumpToCurrent: () -> Void

    @State private var scrub: Double?

    private var duration: Double { player.isLoaded ? player.duration : meeting.info.duration }

    var body: some View {
        let segments = VoiceTimeline.segments(turns: meeting.turns, speakers: meeting.speakers)
        HStack(spacing: 12) {
            Button { player.toggle(meeting) } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Paper.paper)
                    .frame(width: 30, height: 30)
                    .background(Paper.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text(Meeting.timestamp(scrub ?? player.currentTime))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Paper.inkMuted)

            VoiceWave(segments: segments, duration: max(duration, segments.last?.end ?? 0, 0.1),
                      position: player.isLoaded ? (scrub ?? player.currentTime) : nil) { time, done in
                if done {
                    scrub = nil
                    if !player.isLoaded { player.load(meeting: meeting) }
                    player.seek(to: time)
                } else {
                    scrub = time
                }
            }
            .frame(height: 24)

            Text(Meeting.timestamp(duration))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Paper.inkMuted)

            Menu {
                ForEach(PlaybackMath.rates, id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if rate == player.rate {
                            Label(PlaybackMath.rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(PlaybackMath.rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(PlaybackMath.rateLabel(player.rate))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Paper.inkMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
        .overlay(alignment: .top) {
            if player.isPlaying && !player.isFollowing {
                Button("Back to where it's playing", action: jumpToCurrent)
                    .buttonStyle(.paperSecondary)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                    .offset(y: -44)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.isPlaying && !player.isFollowing)
    }
}

/// Coloured bars in proportion to time. Played past the playhead, the rest
/// is paler.
struct VoiceWave: View {
    let segments: [VoiceTimeline.Segment]
    let duration: Double
    /// The playhead; nil before anything is loaded.
    let position: Double?
    /// A time picked by clicking or dragging; `done` when the mouse is up.
    var onSeek: (Double, _ done: Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for s in segments {
                    let x = size.width * s.start / duration
                    let w = max(2, size.width * (s.end - s.start) / duration - 1.5)
                    let h = size.height * s.height
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                    let played = position.map { s.start < $0 } ?? true
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(s.voice.voice.face.opacity(played ? 1 : 0.45)))
                }
                if let position {
                    let x = size.width * min(max(0, position / duration), 1)
                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Paper.ink))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onSeek(time(at: $0.location.x, width: geo.size.width), false) }
                .onEnded { onSeek(time(at: $0.location.x, width: geo.size.width), true) })
        }
        .accessibilityElement()
        .accessibilityLabel("Who speaks when")
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        duration * Double(min(max(0, x / max(width, 1)), 1))
    }
}

/// Where the player bar would be, for meetings whose audio is gone.
struct NoAudioNote: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
            Text("Audio isn't kept for this meeting.")
            Spacer(minLength: 4)
            Button("Audio settings") { state.selection = .engine }
                .buttonStyle(.plain)
                .foregroundStyle(Paper.ink)
                .underline()
        }
        .font(.system(size: 13))
        .foregroundStyle(Paper.inkMuted)
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
    }
}
