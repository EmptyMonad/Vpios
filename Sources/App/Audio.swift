// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation

/// Unciv sound effects (android/assets/sounds, UncivSound.kt / SoundPlayer.kt): every effect is a file name in GameData/Sound;
/// units carry their own `attackSound`, cities bombard, eras have an ambience loop for the city screen (CityAmbiencePlayer).
/// Shared across threads by hand: the audio session, the players (and the loops fading out) are the audio queue's alone,
/// the file cache the main thread's.
final class Audio: @unchecked Sendable {
    static let shared = Audio()
    /// The players live on one serial queue of their own, and only it touches them: AVAudioPlayer's play() waits on the
    /// audio server - 15 to 25 ms a click late in a game - and a tap on the map played its click on the main thread
    /// before the map answered. Unciv never holds a frame for a sound either: a map tap's click goes to the next GL frame
    /// (WorldMapHolder `Concurrency.runOnGLThread("Sound") { SoundPlayer.play(UncivSound.Click) }`) and Android's
    /// SoundPool.play does not block, retrying a sound not yet loaded on a thread of its own (SoundPlayer.playAndroid).
    private let queue = DispatchQueue(label: "epochs.audio", qos: .userInitiated)
    private var players: [String: [AVAudioPlayer]] = [:]   // queue
    private var ambience: AVAudioPlayer?                    // queue
    private var fading: [AVAudioPlayer] = []                // queue: loops fading out, stopped in the order they began to
    /// Unciv SoundPlayer.soundMap: each sound's file, looked up once (a missing one remembered as missing), and forgotten
    /// with the players made from it when the mods it was looked up in change (checkCache's modListHash) - main thread
    private var urls: [String: URL?] = [:]
    private var urlsMods: [String]? = nil
    private let root = Bundle.main.resourceURL!.appendingPathComponent("GameData/Sound")
    private static let extensions = ["mp3", "m4a", "wav", "ogg"]

    // MARK: settings (Unciv GameSettings.soundEffectsVolume / citySoundsVolume)
    var soundEffectsVolume: Float {
        get { epochsAutoplay ? 0 : (UserDefaults.standard.object(forKey: "epochs.soundEffectsVolume") as? Float ?? (UserDefaults.standard.object(forKey: "epochs.sound") as? Bool == false ? 0 : 0.5)) }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.soundEffectsVolume") }
    }
    var citySoundsVolume: Float {
        get { epochsAutoplay ? 0 : (UserDefaults.standard.object(forKey: "epochs.citySoundsVolume") as? Float ?? 0.5) }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.citySoundsVolume"); queue.async { [self] in ambience?.volume = newValue }; if newValue == 0 { stopCityAmbience() } }
    }
    /// Legacy toggles kept for the menu: effects on/off and music on/off map onto the volumes.
    var soundOn: Bool {
        get { soundEffectsVolume > 0 }
        set { soundEffectsVolume = newValue ? max(0.5, soundEffectsVolume) : 0 }
    }
    var musicOn: Bool {
        get { MusicController.shared.musicVolume > 0 && !MusicController.shared.isPaused }
        set { if newValue { if MusicController.shared.musicVolume == 0 { MusicController.shared.musicVolume = 0.5 }; MusicController.shared.resume() } else { MusicController.shared.pause() } }
    }

    /// The audio session - Unciv's Gdx audio needs none of its own - is set up as the audio queue's first job, before any
    /// player: its category and activation wait on the audio server (70 to 140 ms on a simulator, more on a device), and
    /// `shared` is first asked for on the main thread, as the app appears (startMusic, initializeForMainMenu).
    private init() {
        let start = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            DispatchQueue.main.async { [self] in
                sessionReady = true
                let waiting = afterSessionReady; afterSessionReady = []
                for f in waiting { f() }
            }
        }
        if Audio.silentProbe { callerProbe = CallerProbe(initAt: start, initMs: (ProcessInfo.processInfo.systemUptime - start) * 1000, initOnMain: Thread.isMainThread) }
    }

    /// Whether the audio queue has set the session up, and what waits on the main thread for it: the music's players are
    /// the main thread's (MusicController.startTrack), and a track started before would play in the default category,
    /// silencing other apps' audio rather than mixing with it - main thread
    private(set) var sessionReady = false
    private var afterSessionReady: [() -> Void] = []
    func afterSession(_ f: @escaping () -> Void) { if sessionReady { f() } else { afterSessionReady.append(f) } }

    // MARK: --first-tap-selftest
    /// `--first-tap-selftest`: the effects take their whole path as if they were on, whatever the stored volume - every
    /// player at volume 0, so the measurement is heard nowhere - and what the caller's thread spends in Audio is timed
    static let silentProbe = CommandLine.arguments.contains("--first-tap-selftest")
    /// what the caller's thread spent: Audio's init (once, before `shared` is handed out) and the last play() (the main thread's)
    struct CallerProbe { var initAt: TimeInterval = 0; var initMs = 0.0; var initOnMain = false; var lastPlayMs = 0.0 }
    private(set) var callerProbe = CallerProbe()
    /// the audio queue's: when the preloaded players were ready (systemUptime), and from the last play() to its player's play()
    struct QueueProbe { var preloadDone: TimeInterval? = nil; var lastPlayLagMs = 0.0 }
    private var queueProbe = QueueProbe()
    /// the queue's probe handed to `f` on the main thread once the jobs asked for before it have run - the main thread
    /// never waits for them
    func readQueueProbe(_ f: @escaping (QueueProbe) -> Void) { queue.async { [self] in let p = queueProbe; DispatchQueue.main.async { f(p) } } }

    func url(for name: String) -> URL? {
        for ext in Audio.extensions {
            let u = root.appendingPathComponent(name + "." + ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // mods may ship their own sounds/<name>.*
        for mod in soundMods {
            for ext in Audio.extensions {
                let u = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent("sounds/\(name).\(ext)")
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// Unciv SoundPlayer.getFolders: the game's ruleset mods, then the permanent audiovisual mods
    private var soundMods: [String] { Ruleset.shared.mods + UserSettings.visualMods.filter({ !Ruleset.shared.mods.contains($0) }) }
    /// Unciv SoundPlayer.initializeForMainMenu - `checkCache()`, from MainMenuScreen's init - so the Preloader has the
    /// effects ready before the first tap on the menu or the map: called as the app appears (Unciv's first screen is the
    /// main menu, a game loaded at launch included) and each time the main menu comes back.
    func initializeForMainMenu() { checkCache() }
    /// Unciv SoundPlayer.checkCache: the first time, or with another mod list, the cache is emptied (clearCache) and the
    /// Preloader restarted
    private func checkCache() {
        let mods = soundMods
        guard mods != urlsMods else { return }
        let first = urlsMods == nil
        urlsMods = mods; urls.removeAll()
        if !first { queue.async { [self] in players.removeAll() } }
        preload()
    }
    /// Unciv SoundPlayer.get: the cache checked, then the cached file, looked up on first use
    private func cachedURL(for name: String) -> URL? {
        checkCache()
        return known(name)
    }
    private func known(_ name: String) -> URL? {
        if let u = urls[name] { return u }
        let found = url(for: name)
        urls[name] = found
        return found
    }
    /// Unciv SoundPlayer.Preloader: Click, Whoosh, Construction, Promote, Upgrade, Coin, Chimes and Choir are loaded in the
    /// background, one after another (`if (sound in soundMap) continue`), whatever the volume, so the first of each plays
    /// at once - on a thread of its own (`Concurrency.run("SoundPreloader")`): play() never waits for it, SoundPlayer.get
    /// loading a sound not cached yet itself. Here the loads run on the preload queue and each player is handed to the
    /// audio queue, which alone keeps them, so a sound asked for meanwhile waits for no load but its own; Preloader.restart
    /// (`job.cancel()`) is a later preload's generation, which stops the earlier one before its next load and keeps a load
    /// already under way out of the new cache.
    private func preload() {
        let files = ["click", "whoosh", "construction", "promote", "upgrade", "coin", "chimes", "choir"].compactMap { name in
            known(name).map { (name, $0) }
        }
        queue.async { [self] in
            preloadGeneration += 1
            let generation = preloadGeneration
            preloadQueue.async { [self] in
                for (name, url) in files {
                    // (asked of the audio queue, the cache's owner: a cancelled preload stops, a cached sound is skipped)
                    let wanted: Bool? = queue.sync { generation == preloadGeneration ? players[name] == nil : nil }
                    guard let wanted else { return }
                    guard wanted, let p = try? AVAudioPlayer(contentsOf: url) else { continue }
                    p.prepareToPlay()
                    let loaded = LoadedPlayer(p)
                    queue.async { [self] in if generation == preloadGeneration && players[name] == nil { players[name] = [loaded.player] } }
                }
                if Audio.silentProbe { queue.async { [self] in queueProbe.preloadDone = ProcessInfo.processInfo.systemUptime } }
            }
        }
    }
    private var preloadGeneration = 0   // queue
    private let preloadQueue = DispatchQueue(label: "epochs.audio.preload", qos: .userInitiated)
    /// A player on its way from the preload queue to the audio queue, which alone touches it from then on
    private final class LoadedPlayer: @unchecked Sendable { let player: AVAudioPlayer; init(_ p: AVAudioPlayer) { player = p } }

    /// Unciv SoundPlayer.play: `name` is an UncivSound file name (click, coin, chimes, whoosh, …) or a unit attack sound.
    /// The volume and the file are settled here, the playing on the audio queue: nothing is queued while the effects are
    /// silent, and a sound follows the ones asked for before it.
    func play(_ name: String, volume: Float = 1) {
        let probeStart = Audio.silentProbe ? ProcessInfo.processInfo.systemUptime : 0
        defer { if Audio.silentProbe { callerProbe.lastPlayMs = (ProcessInfo.processInfo.systemUptime - probeStart) * 1000 } }
        let vol = (Audio.silentProbe ? 1 : soundEffectsVolume) * volume
        guard vol > 0, !name.isEmpty, let url = cachedURL(for: name) else { return }
        let out = Audio.silentProbe ? 0 : vol
        queue.async { [self] in
            defer { if Audio.silentProbe { queueProbe.lastPlayLagMs = (ProcessInfo.processInfo.systemUptime - probeStart) * 1000 } }
            var pool = players[name] ?? []
            if let free = pool.first(where: { !$0.isPlaying }) { free.volume = out; free.currentTime = 0; free.play(); return }
            guard pool.count < 4, let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.volume = out; p.prepareToPlay(); p.play()
            pool.append(p); players[name] = pool
        }
    }
    /// Unciv SoundPlayer.playRepeated (promotions play once per step, at most twice).
    func playRepeated(_ name: String, count: Int) {
        play(name)
        if count > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.play(name) } }
    }
    /// Unciv MapUnitCombatant.getAttackSound: the unit's `attackSound`, or a click when it has none.
    func playAttack(_ unit: UnitDef) { play(unit.attackSound ?? "click") }
    /// Unciv CityCombatant.getAttackSound.
    func playCityAttack() { play("bombard") }

    // MARK: city ambience (Unciv CityAmbiencePlayer: era.citySound looping while the city screen is open)
    /// The loop is loaded and started on the audio queue too; the volume and the file are read here.
    func startCityAmbience(era: EraDef?) {
        stopCityAmbience()
        let vol = citySoundsVolume
        guard vol > 0, let name = era?.citySound, !name.isEmpty, let url = cachedURL(for: name) else { return }
        queue.async { [self] in
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.numberOfLoops = -1; p.volume = 0; p.prepareToPlay(); p.play()
            p.setVolume(vol, fadeDuration: 0.9)
            ambience = p
        }
    }
    func stopCityAmbience() {
        queue.async { [self] in
            guard let p = ambience else { return }
            p.setVolume(0, fadeDuration: 0.4)
            fading.append(p)
            queue.asyncAfter(deadline: .now() + 0.45) { [self] in if !fading.isEmpty { fading.removeFirst().stop() } }
            ambience = nil
        }
    }

    // Legacy entry points, kept so older callers keep working.
    /// Unciv UncivGame.create: `musicController.chooseTrack(suffixes = listOf(MusicMood.Menu, MusicMood.Ambient),
    /// flags = EnumSet.of(MusicTrackChooserFlags.SuffixMustMatch))` before the language picker or the main menu
    func startMusic() { MusicController.shared.chooseTrack(suffixes: [MusicMood.menu, MusicMood.ambient], flags: .suffixMustMatch) }
    func stopMusic() { MusicController.shared.pause() }
}
