// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv WorldScreenMusicPopup + MusicControls: "Currently playing", pause / resume / skip, music volume,
/// pause between tracks (MusicControls.addMusicControls - no "Download music", which only SoundTab offers) and the
/// track lists (default folder, mods, history).
struct MusicPopup: View {
    let onClose: () -> Void
    @State private var current = MusicController.shared.currentTrack
    @State private var volume = Double(MusicController.shared.musicVolume)
    /// Unciv MusicControls.addMusicPauseSlider: slider positions 0..30, `initial = lengthToPos(music.silenceLength)`
    @State private var pausePos = OptionsView.lengthToPos(Double(MusicController.shared.pauseBetweenTracks))
    @State private var tick = 0

    var body: some View {
        let music = MusicController.shared
        ThemedDialog(title: L("Music"), onDismiss: onClose) {
            let _ = tick
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Currently playing: [\(current.display)]")).font(Theme.caption).foregroundStyle(Color(red: 0.82, green: 0.69, blue: 1))
                    HStack(spacing: 8) {
                        Button { music.pause(speedFactor: 0.5); refresh() } label: { Image(systemName: "pause.fill") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button { music.resume(speedFactor: 0.5); refresh() } label: { Image(systemName: "play.fill") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button { music.skip(); refresh() } label: { Image(systemName: "forward.end.fill") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Spacer()
                    }
                    // Unciv MusicControls.addMusicVolumeSlider: setVolume, then a track (setPlayDefault) when none plays
                    VolumeRow(title: L("Music volume"), value: $volume) { v in
                        music.musicVolume = Float(v)
                        if !music.isPlaying { music.chooseTrack(flags: .setPlayDefault) }
                        refresh()
                    }
                    // Unciv MusicControls.addMusicPauseSlider: positions 0..30 map to 0-1-2..10-12-14..30-35-40..60-75-90-105-120 seconds
                    HStack {
                        Text(L("Pause between tracks")).font(Theme.body); Spacer()
                        // getTipText: "%.0f".format(posToLength(it)) - the device's locale, no unit
                        Text(String(format: "%.0f", locale: Locale.current, OptionsView.posToLength(pausePos))).font(Theme.caption).foregroundStyle(Theme.creamDim)
                    }
                    EpochsSlider(value: $pausePos, range: 0...30, step: 1).frame(height: 28).onChange(of: pausePos) { _, v in music.pauseBetweenTracks = Int(OptionsView.posToLength(v)) }
                }
            }
            let tracks = music.allMusicFiles()
            let mods = Dictionary(grouping: tracks, by: { $0.mod })
            // Unciv addMusicMods: each mod's tracks sorted by name
            ForEach(mods.keys.sorted(), id: \.self) { mod in
                trackList(mod.isEmpty ? "—Default—" : mod, (mods[mod] ?? []).sorted { $0.track < $1.track })
            }
            // Unciv addHistory: musicController.getHistory() - the order the tracks were played in
            if !music.history.isEmpty { trackList("—History—", music.history) }
            Button(L("Close")) { onClose() }.buttonStyle(ThemedButtonStyle(compact: true))   // Unciv WorldScreenMusicPopup: addCloseButton()
        }
        .onAppear { music.onChange = { t in current = t } }
        .onDisappear { music.onChange = nil }
    }

    private func trackList(_ title: String, _ tracks: [MusicController.TrackInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title)
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in   // the history may list a track twice
                        ThemedRow(title: t.track, detail: t.type, selected: t == current, action: { MusicController.shared.startTrack(t); refresh() },
                                  leading: { Image(systemName: t == current ? "speaker.wave.2.fill" : "music.note").foregroundStyle(Theme.gold) }, trailing: { EmptyView() })
                    }
                }
            }
        }
    }
    private func refresh() { current = MusicController.shared.currentTrack; tick += 1 }
}

/// Unciv MusicControls.addVolumeSlider: label + 0…1 slider (custom slider – SwiftUI's hangs inside full-screen covers here).
struct VolumeRow: View {
    let title: String
    @Binding var value: Double
    let onChange: (Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // UncivSlider.formatPercent: (value * 100f + 0.5f).toInt().tr() + "%"
            HStack { Text(title).font(Theme.body); Spacer(); Text(Translations.shared.numberTr(Int(value * 100 + 0.5)) + "%").font(Theme.caption).foregroundStyle(Theme.creamDim) }
            EpochsSlider(value: $value, range: 0...1, step: 0.05).frame(height: 28).onChange(of: value) { _, v in onChange(v) }
        }
    }
}
