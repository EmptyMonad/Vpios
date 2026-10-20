// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation

/// Unciv MusicMood: track name suffixes used to pick music for a situation.
enum MusicMood {
    static let theme = "Theme", peace = "Peace", war = "War", defeat = "Defeat", menu = "Menu", ambient = "Ambient"
    static let golden = "Golden", wonder = "Wonder", researched = "Researched", victory = "Victory"
    static let themeOrPeace = [theme, peace]
    static func peaceOrWar(_ atWar: Bool) -> String { atWar ? war : peace }
}

/// Unciv MusicTrackChooserFlags.
struct MusicTrackChooserFlags: OptionSet {
    let rawValue: Int
    static let prefixMustMatch = MusicTrackChooserFlags(rawValue: 1)
    static let suffixMustMatch = MusicTrackChooserFlags(rawValue: 2)
    static let slowFade = MusicTrackChooserFlags(rawValue: 4)
    static let playDefaultFile = MusicTrackChooserFlags(rawValue: 8)
    static let setSpecific: MusicTrackChooserFlags = [.prefixMustMatch, .suffixMustMatch]
    static let setSelectNation: MusicTrackChooserFlags = [.prefixMustMatch]
    static let setNextTurn: MusicTrackChooserFlags = [.prefixMustMatch, .slowFade]
    static let setPlayDefault: MusicTrackChooserFlags = [.playDefaultFile]
    static let none: MusicTrackChooserFlags = []
}

/// Unciv MusicController (core/ui/audio/MusicController.kt): music lives in Documents/music (and mods/<mod>/music),
/// tracks are chosen by prefix (civ/tech/wonder name) and suffix (mood), fade in/out, pause between tracks,
/// history of the last 8 tracks. Unciv's downloadable default track (a third-party piece fetched from Dropbox) is left
/// out: the app plays its own generated music and whatever the player puts in Documents/music or a mod.
final class MusicController: NSObject, AVAudioPlayerDelegate {
    nonisolated(unsafe) static let shared = MusicController()

    struct TrackInfo: Equatable, Identifiable {
        let mod: String; let track: String; let type: String; let url: URL?
        var id: String { url?.path ?? "" }
        var display: String { track.isEmpty ? "—Paused—" : mod.isEmpty ? track : "\(mod): \(track)" }
        static let paused = TrackInfo(mod: "", track: "", type: "", url: nil)
    }

    static let musicPath = "music"
    static let maxVolume: Float = 0.6
    static let defaultFadeDuration: TimeInterval = 0.9
    static let musicHistorySize = 8
    static let supportedExtensions = ["mp3", "m4a", "wav", "aac", "ogg"]

    var musicVolume: Float {
        get { epochsAutoplay ? 0 : (UserDefaults.standard.object(forKey: "epochs.musicVolume") as? Float ?? (UserDefaults.standard.object(forKey: "epochs.music") as? Bool == false ? 0 : 0.5)) }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.musicVolume"); setVolume(newValue) }
    }
    /// Unciv GameSettings.pauseBetweenTracks (seconds).
    var pauseBetweenTracks: Int {
        get { UserDefaults.standard.object(forKey: "epochs.pauseBetweenTracks") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.pauseBetweenTracks") }
    }

    private var current: AVAudioPlayer?
    private var next: AVAudioPlayer?
    private(set) var currentTrack: TrackInfo = .paused
    private(set) var isPaused = false
    private var musicHistory: [String] = []
    private var silenceTimer: Timer?
    private var fadeWork: DispatchWorkItem?
    var onChange: ((TrackInfo) -> Void)?
    var mods: [String] = []

    static var documentsMusicFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(musicPath)
    }

    // MARK: files
    private func musicFolders() -> [(mod: String, url: URL)] {
        var out: [(String, URL)] = []
        for m in Set(mods + Ruleset.shared.mods + UserSettings.visualMods) { out.append((m, Ruleset.modsDirectory.appendingPathComponent(m).appendingPathComponent(MusicController.musicPath))) }
        out.append(("", MusicController.documentsMusicFolder))
        return out.filter { (try? $0.1.checkResourceIsReachable()) ?? false }
    }
    func allMusicFiles() -> [TrackInfo] {
        var out: [TrackInfo] = []
        for (mod, folder) in musicFolders() {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for f in files where MusicController.supportedExtensions.contains(f.pathExtension.lowercased()) {
                out.append(TrackInfo(mod: mod, track: f.deletingPathExtension().lastPathComponent, type: f.pathExtension, url: f))
            }
        }
        // Epochs ships a generated ambient loop, its own music
        if let bundled = Bundle.main.url(forResource: "ambient", withExtension: "wav", subdirectory: "GameData/Sound") {
            out.append(TrackInfo(mod: "", track: "Epochs Ambient", type: "wav", url: bundled))
        }
        return out
    }
    var isMusicAvailable: Bool { !allMusicFiles().isEmpty }
    var history: [TrackInfo] { musicHistory.compactMap { p in allMusicFiles().first { $0.url?.path == p } } }
    var isPlaying: Bool { current?.isPlaying ?? false }

    private func chooseFile(prefix: String, suffix: String, flags: MusicTrackChooserFlags) -> TrackInfo? {
        let prefixMust = flags.contains(.prefixMustMatch), suffixMust = flags.contains(.suffixMustMatch)
        return allMusicFiles()
            .filter { (!prefixMust || $0.track.hasPrefix(prefix)) && (!suffixMust || $0.track.hasSuffix(suffix)) }
            .shuffled()
            .sorted { a, b in
                let ka = (a.track.hasPrefix(prefix) ? 0 : 1, a.track.hasSuffix(suffix) ? 0 : 1, musicHistory.contains(a.url?.path ?? "") ? 1 : 0)
                let kb = (b.track.hasPrefix(prefix) ? 0 : 1, b.track.hasSuffix(suffix) ? 0 : 1, musicHistory.contains(b.url?.path ?? "") ? 1 : 0)
                return ka < kb
            }
            .first
    }

    // MARK: playback
    /// Unciv chooseTrack(prefix, suffixes, flags): try each suffix in turn; returns whether a track was started.
    @discardableResult
    func chooseTrack(prefix: String = "", suffixes: [String] = [MusicMood.ambient], flags: MusicTrackChooserFlags = []) -> Bool {
        for s in suffixes { if chooseTrack(prefix: prefix, suffix: s, flags: flags) { return true } }
        return false
    }
    @discardableResult
    func chooseTrack(prefix: String, suffix: String, flags: MusicTrackChooserFlags) -> Bool {
        // (`--first-tap-selftest` takes the music's way whatever the volume, at volume 0: Audio.silentProbe)
        guard musicVolume > 0 || Audio.silentProbe else { return false }
        guard let file = chooseFile(prefix: prefix, suffix: suffix, flags: flags) else { return false }
        // Unciv startTrack: `if (musicFile.path() == currentlyPlaying()) return true` - the track not playing yet (waiting for
        // the audio session, or loading) counts as the one playing, as Unciv's is from the moment it is loaded
        if file == currentTrack, isPlaying { return true }
        if let pending = pendingTrack, pending.info == file { return true }
        return startTrack(file, slowFade: flags.contains(.slowFade))
    }
    /// The track asked for last that is not playing yet - waiting for the audio session or being loaded - and its
    /// number: a later startTrack (Unciv: `next?.clear(); next = MusicTrackController(...)`), a pause or a shutdown drops
    /// the one under way, whose player is stopped as it arrives
    private var pendingTrack: (info: TrackInfo, slowFade: Bool)? = nil
    private var pendingSerial = 0
    private var waitingForSession = false
    /// The players are made, prepared and started here, off the main thread: a track's AVAudioPlayer held the main thread
    /// 0.4 to 0.8 s on a busy simulator (Unciv's Gdx.audio.newMusic only opens a stream), and the tracks asked for at launch
    /// came as the world screen was shown, holding its first tap behind them. Not Audio's queue, whose effects would wait.
    private static let loadQueue = DispatchQueue(label: "epochs.music", qos: .userInitiated)
    /// `--first-tap-selftest`: the main thread's time in startTrack and in taking the loaded player over (`maxMs`,
    /// `totalMs`), the load's on the music queue (`loadMaxMs`), the tracks started and when the last one was asked for
    /// (systemUptime)
    struct StartProbe { var count = 0; var maxMs = 0.0; var totalMs = 0.0; var loadMaxMs = 0.0; var lastAt: TimeInterval = 0 }
    private(set) var startProbe = StartProbe()
    private func probeMain(_ start: TimeInterval) {
        guard Audio.silentProbe else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        startProbe.totalMs += ms; startProbe.maxMs = max(startProbe.maxMs, ms)
    }
    /// Unciv startTrack: `if (!musicFile.exists()) return false`, then the track is loaded (MusicTrackController.load) and,
    /// loaded, played and faded in over the one playing (onSuccess) - here once the audio session is set up (on Audio's
    /// queue: a track asked for before it, the menu's or a game's loaded at launch, plays mixed with other apps' audio as
    /// every track does) and the player made on the music queue.
    @discardableResult
    func startTrack(_ info: TrackInfo, slowFade: Bool = false) -> Bool {
        guard let url = info.url, FileManager.default.fileExists(atPath: url.path) else { return false }
        let probeStart = ProcessInfo.processInfo.systemUptime
        defer { probeMain(probeStart) }
        if Audio.silentProbe { startProbe.count += 1; startProbe.lastAt = probeStart }
        pendingSerial += 1
        pendingTrack = (info, slowFade)
        if !Audio.shared.sessionReady {
            if !waitingForSession {
                waitingForSession = true
                Audio.shared.afterSession { [weak self] in
                    guard let self else { return }
                    self.waitingForSession = false
                    if let t = self.pendingTrack { self.load(t.info, slowFade: t.slowFade, serial: self.pendingSerial) }
                }
            }
            return true
        }
        load(info, slowFade: slowFade, serial: pendingSerial)
        return true
    }
    private func load(_ info: TrackInfo, slowFade: Bool, serial: Int) {
        guard let url = info.url else { return }
        let loops = info.track == "Epochs Ambient" ? -1 : 0
        let back = MusicHandOver(controller: self)
        MusicController.loadQueue.async {
            let t = ProcessInfo.processInfo.systemUptime
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = loops
            player?.volume = 0
            player?.prepareToPlay()
            player?.play()
            back.player = player
            back.loadMs = (ProcessInfo.processInfo.systemUptime - t) * 1000
            DispatchQueue.main.async { back.arrive(info, slowFade: slowFade, serial: serial) }
        }
    }
    /// The loaded player taken over on the main thread - or stopped, when another track, a pause or a shutdown came since
    fileprivate func adopt(_ player: AVAudioPlayer?, _ info: TrackInfo, slowFade: Bool, serial: Int, loadMs: Double) {
        let probeStart = ProcessInfo.processInfo.systemUptime
        defer { probeMain(probeStart) }
        if Audio.silentProbe { startProbe.loadMaxMs = max(startProbe.loadMaxMs, loadMs) }
        guard serial == pendingSerial else { player?.stop(); return }
        pendingTrack = nil
        guard let player else { return }   // a file AVAudioPlayer cannot open plays nothing
        silenceTimer?.invalidate(); silenceTimer = nil
        fadeWork?.cancel()
        player.delegate = self
        let fade = MusicController.defaultFadeDuration * (slowFade ? 5 : 1)
        if let old = current {
            old.setVolume(0, fadeDuration: fade)
            let work = DispatchWorkItem { old.stop() }
            fadeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05, execute: work)
        }
        current = player
        currentTrack = info
        isPaused = false
        player.setVolume(Audio.silentProbe ? 0 : musicVolume * MusicController.maxVolume, fadeDuration: fade)
        if let p = info.url?.path { musicHistory.append(p); if musicHistory.count > MusicController.musicHistorySize { musicHistory.removeFirst() } }
        onChange?(info)
    }
    func pause(speedFactor: Float = 1) {
        pendingTrack = nil; pendingSerial += 1   // a track not playing yet does not start
        guard let p = current, p.isPlaying else { return }
        isPaused = true
        p.setVolume(0, fadeDuration: MusicController.defaultFadeDuration / Double(max(0.1, speedFactor)))
        let work = DispatchWorkItem { [weak p] in p?.pause() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MusicController.defaultFadeDuration / Double(max(0.1, speedFactor)) + 0.05, execute: work)
        silenceTimer?.invalidate(); silenceTimer = nil
        onChange?(.paused)
    }
    func resume(speedFactor: Float = 1) {
        fadeWork?.cancel()
        isPaused = false
        if let p = current, !p.isPlaying {
            p.play(); p.setVolume(musicVolume * MusicController.maxVolume, fadeDuration: MusicController.defaultFadeDuration / Double(max(0.1, speedFactor)))
            onChange?(currentTrack)
        } else if current == nil { chooseTrack() }
    }
    func fadeoutToSilence(duration: TimeInterval = MusicController.defaultFadeDuration * 5) {
        guard let p = current else { return }
        p.setVolume(0, fadeDuration: duration)
        let work = DispatchWorkItem { [weak self] in p.stop(); if self?.current === p { self?.current = nil; self?.currentTrack = .paused; self?.onChange?(.paused) } }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: work)
    }
    /// Unciv MusicController.setVolume: below 0.01 the music shuts down, otherwise a playing track takes the new volume.
    /// Nothing starts here - MusicControls.addMusicVolumeSlider then chooses a track (setPlayDefault) when none plays.
    func setVolume(_ v: Float) {
        if v < 0.01 { shutdown() } else if isPlaying { current?.volume = v * MusicController.maxVolume }
    }
    /// Unciv MusicController.shutdown: idle (the change listener hears it and is kept), no timer, no track, no history.
    private func shutdown() {
        currentTrack = .paused; isPaused = false   // state = ControllerState.Idle
        pendingTrack = nil; pendingSerial += 1
        onChange?(.paused)                          // fireOnChange()
        silenceTimer?.invalidate(); silenceTimer = nil   // stopTimer()
        next?.stop(); next = nil
        current?.stop(); current = nil
        musicHistory.removeAll()
    }
    func skip() { chooseTrack(flags: .none) }
    func gracefulShutdown() { fadeoutToSilence(duration: 0.4) }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.current else { return }
            self.currentTrack = .paused; self.onChange?(.paused)
            let pause = TimeInterval(self.pauseBetweenTracks)
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, pause), repeats: false) { [weak self] _ in self?.chooseTrack() }
        }
    }
}

/// A track's player on its way from the music queue to the main thread, which alone touches MusicController
private final class MusicHandOver: @unchecked Sendable {
    weak var controller: MusicController?
    var player: AVAudioPlayer?
    var loadMs = 0.0
    init(controller: MusicController) { self.controller = controller }
    func arrive(_ info: MusicController.TrackInfo, slowFade: Bool, serial: Int) {
        guard let c = controller else { player?.stop(); return }
        c.adopt(player, info, slowFade: slowFade, serial: serial, loadMs: loadMs)
    }
}
