// VPiOS: the mods this build ships with (Civ V Brave New World, Vox Populi 4.22), copied into Documents/Mods so they
// show in the new game screen without a download, and a headless self-test (`-vpSelfTest <turns>`) used by CI.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum BundledMods {
    static let names = ["Civ V Brave New World", "Vox Populi 4.22"]

    /// Copies each bundled mod into Documents/Mods when it is missing or the bundled copy is newer (a stamp file holds
    /// the build it came from). A mod the player downloaded under the same name is replaced only by a newer build.
    static func install() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("GameData/BundledMods") else { return }
        let fm = FileManager.default
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") + "-" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        for name in names {
            let src = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = Ruleset.modsDirectory.appendingPathComponent(name)
            let stamp = dst.appendingPathComponent(".vpios-bundled")
            if let have = try? String(contentsOf: stamp, encoding: .utf8), have == build { continue }
            try? fm.removeItem(at: dst)
            do {
                try fm.copyItem(at: src, to: dst)
                try build.write(to: stamp, atomically: true, encoding: .utf8)
            } catch { print("BundledMods: \(name): \(error)") }
        }
        Ruleset.clearModOptionsCache()
    }
}

enum VPSelfTest {
    /// `-vpSelfTest [turns]`: an all-AI game on G&K + BNW + VP, printing each major civ's happiness every 10 turns.
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-vpSelfTest") else { return }
        let turns = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 100
        let worker = Thread {
            epochsAutoplay = true
            setvbuf(stdout, nil, _IOLBF, 0)
            var s = GameSettings()
            s.seed = 42
            s.baseRuleset = Ruleset.baseRulesetName
            s.mods = BundledMods.names
            s.players = (0..<5).map { _ in PlayerSetup(chosenCiv: "Random", isHuman: false) }
            let g: GameState
            do { g = try GameState.newGame(settings: s) } catch { print("VPTEST could not start: \(error)"); exit(2) }
            print("VPTEST start mods=\(Ruleset.shared.mods) vpNeeds=\(g.vpNeeds != nil) vpData=\(g.vpData != nil) buildings=\(Ruleset.shared.buildings.count) units=\(Ruleset.shared.units.count)")
            let t0 = Date()
            for t in 1...turns {
                g.endTurn()
                if t % 10 == 0 || g.outcome != nil {
                    print("VPTEST turn \(g.turn) \(Int(Date().timeIntervalSince(t0)))s medians=\(g.vpMedians)")
                    for c in g.civs where c.isMajor && c.isAlive {
                        let h = g.happinessBreakdown(c.id)
                        let rows = h.rows.map { "\($0.0)=\(Int($0.1))" }.joined(separator: ",")
                        let cs = g.cities(of: c.id)
                        print("VPTEST   \(c.nation): gold=\(Int(c.gold)) culture=\(Int(c.totalCulture)) policies=\(c.policies.count) techs=\(c.techs.count) ww=\(g.vpWarWearinessPercent(c.id))% units=\(g.units(of: c.id).count) supply=\(g.unitSupply(c.id)) cities=\(cs.count) pop=\(cs.reduce(0) { $0 + $1.population }) happiness=\(g.happiness(of: c.id)) approval=\(g.vpApproval(civId: c.id).map(String.init) ?? "-") monopolies=\(g.vpMonopolies()[c.id].map { $0.global.sorted().joined(separator: "/") } ?? "-") corp=\(g.vpCorporation(of: c.id).map { "\($0.name) \(g.vpFranchiseCount($0, owner: c.id))/\(g.vpFranchiseLimit($0, owner: c.id))" } ?? "-") [\(rows)]")
                    }
                }
                if t == 20 && !g.civs.contains(where: { $0.isMajor && !g.cities(of: $0.id).isEmpty }) { print("VPTEST FAIL no major civ has founded a city by turn 20") }
                if g.outcome != nil { break }
            }
            print("VPTEST done")
            exit(0)
        }
        worker.stackSize = 256 << 20   // the turn needs far more than a secondary thread's default 512 KB
        worker.start()
    }
}
