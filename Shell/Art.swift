// Shell for the Unciv 4X core (MPL-2.0): art lookup. The store build's own artwork isn't published, so this draws Unciv's
// own tilesets and icons (bundled raw under GameData/Art, keyed as in Unciv's atlas: "UnitIcons/Warrior",
// "TileSets/HexaRealm/Tiles/Grassland"). Tile layering follows Unciv TileLayerTerrain.getTileBaseImageLocations.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SpriteKit
import UIKit

final class Art {
    static let shared = Art()

    /// HD medallion art is the store build's own; never on here.
    let hd = false

    var tileSet: String {
        get { UserDefaults.standard.string(forKey: "vpios.tileSet") ?? "HexaRealm" }
        set { UserDefaults.standard.set(newValue, forKey: "vpios.tileSet"); configCache = [:] }
    }
    var unitSet: String {
        get { UserDefaults.standard.string(forKey: "vpios.unitSet") ?? "AbsoluteUnits" }
        set { UserDefaults.standard.set(newValue, forKey: "vpios.unitSet") }
    }

    /// atlas key -> file
    private var files: [String: URL] = [:]
    private var textures: [String: SKTexture] = [:]
    private var images: [String: UIImage] = [:]
    private let lock = NSLock()

    private init() {
        if let root = Bundle.main.resourceURL?.appendingPathComponent("GameData/Art") { index(root) }
    }

    private func index(_ root: URL) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        let base = root.standardizedFileURL.path + "/"
        for case let u as URL in e where u.pathExtension.lowercased() == "png" {
            let rel = u.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            files[String(rel.dropLast(4))] = u
        }
    }

    /// Unciv mods may carry an `Images/` folder laid out like the atlas; later mods win.
    func reloadModRoots(mods: [String]) {
        lock.lock(); defer { lock.unlock() }
        files = [:]; textures = [:]; images = [:]; configCache = [:]
        if let root = Bundle.main.resourceURL?.appendingPathComponent("GameData/Art") { index(root) }
        for m in mods { index(Ruleset.modsDirectory.appendingPathComponent(m).appendingPathComponent("Images")) }
    }

    func exists(_ key: String) -> Bool { files[key] != nil }

    private func textureFor(key: String) -> SKTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = textures[key] { return t }
        guard let url = files[key], let img = UIImage(contentsOfFile: url.path) else { return nil }
        let t = SKTexture(image: img)
        t.filteringMode = .linear
        textures[key] = t
        return t
    }

    func image(_ name: String, folder: String) -> UIImage? {
        guard let key = resolve(name, folder: folder) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let i = images[key] { return i }
        guard let url = files[key], let img = UIImage(contentsOfFile: url.path) else { return nil }
        images[key] = img
        return img
    }

    /// `folder` nil: a tile-layer name ("Grassland+Forest", "River-Bottom", "Highlight") in the tileset (or its fallback).
    func texture(_ name: String, folder: String? = nil) -> SKTexture? {
        guard let key = resolve(name, folder: folder) else { return nil }
        return textureFor(key: key)
    }

    func unitTexture(_ artName: String) -> SKTexture? {
        for set in chain(unitSet) + chain(tileSet) {
            let k = "TileSets/\(set)/Units/\(artName)"
            if exists(k) { return textureFor(key: k) }
        }
        return nil
    }

    func availableSets(units: Bool = false) -> [String] {
        var sets = Set<String>()
        for k in files.keys where k.hasPrefix("TileSets/") {
            let parts = k.split(separator: "/")
            guard parts.count >= 3 else { continue }
            if units ? parts[2] == "Units" : parts[2] == "Tiles" { sets.insert(String(parts[1])) }
        }
        return sets.sorted()
    }

    // MARK: tileset config (jsons/TileSets/<set>.json, bundled as GameData/TileSets)

    struct TileSetConfig { var fallback: String?; var ruleVariants: [String: [String]] }
    private var configCache: [String: TileSetConfig] = [:]
    func config(_ set: String) -> TileSetConfig {
        if let c = configCache[set] { return c }
        var c = TileSetConfig(fallback: set == "FantasyHex" ? nil : "FantasyHex", ruleVariants: [:])
        if let url = Bundle.main.url(forResource: set, withExtension: "json", subdirectory: "GameData/TileSets"),
           let raw = try? Data(contentsOf: url), let clean = Ruleset.cleanedModJSON(raw),
           let obj = try? JSONSerialization.jsonObject(with: clean) as? [String: Any] {
            if obj.keys.contains("fallbackTileSet") { c.fallback = obj["fallbackTileSet"] as? String }
            c.ruleVariants = (obj["ruleVariants"] as? [String: [String]]) ?? [:]
        }
        configCache[set] = c
        return c
    }
    private func chain(_ set: String) -> [String] {
        var out = [set], cur = set
        while let f = config(cur).fallback, !out.contains(f), out.count < 3 { out.append(f); cur = f }
        return out
    }

    private func resolve(_ name: String, folder: String?) -> String? {
        if name.contains("/"), exists(name) { return name }
        guard let folder else {
            for set in chain(tileSet) {
                for k in ["TileSets/\(set)/Tiles/\(name)", "TileSets/\(set)/\(name)"] where exists(k) { return k }
            }
            return nil
        }
        switch folder {
        case "Tiles", "Roads", "Arrows", "Borders", "Edges":
            for set in chain(tileSet) {
                let sub = folder == "Roads" ? "" : folder + "/"
                for k in ["TileSets/\(set)/\(sub)\(name)", "TileSets/\(set)/\(name)"] where exists(k) { return k }
            }
            return nil
        case "Units":
            for set in chain(unitSet) + chain(tileSet) where exists("TileSets/\(set)/Units/\(name)") { return "TileSets/\(set)/Units/\(name)" }
            return nil
        default:
            let k = "\(folder)/\(name)"
            return exists(k) ? k : nil
        }
    }

    // MARK: Unciv TileLayerTerrain.getTileBaseImageLocations

    /// The tile's base image names, bottom to top, as names `texture(_:)` resolves in the tileset.
    func layers(for tile: Tile, cityEra: String?) -> [String] {
        let sets = chain(tileSet)
        func tileExists(_ n: String) -> Bool { sets.contains { exists("TileSets/\($0)/Tiles/\(n)") } }
        func inMain(_ n: String) -> Bool { exists("TileSets/\(sets[0])/Tiles/\(n)") }
        func variants(_ n: String) -> [String] { config(sets[0]).ruleVariants[n] ?? (sets.count > 1 ? config(sets[1]).ruleVariants[n] : nil) ?? [] }

        var resImp: [String] = []
        if let r = tile.resource { resImp.append(r) }
        if let i = tile.improvement {
            resImp.append(tile.pillaged && tileExists("\(i)-Pillaged") ? "\(i)-Pillaged" : i)
        }
        var terrain = [tile.baseTerrain]
        if let w = tile.naturalWonder { terrain.append(w) } else { terrain += tile.features }

        let allTogether = !resImp.isEmpty ? (terrain + resImp).joined(separator: "+")
            : (tile.naturalWonder == nil && tile.features.isEmpty ? tile.baseTerrain : terrain.joined(separator: "+"))

        var out: [String]
        let rv = variants(allTogether)
        if !rv.isEmpty { out = rv }
        else if inMain(allTogether) { out = [allTogether] }
        else if let w = tile.naturalWonder { out = [w] }
        else {
            // getTerrainImageLocations
            let terrains = terrain.joined(separator: "+")
            let trv = variants(terrains)
            if !trv.isEmpty { out = trv }
            else if inMain(terrains) { out = [terrains] }
            else { out = terrain }
            // getImprovementAndResourceImages
            if !resImp.isEmpty {
                let both = resImp.joined(separator: "+")
                out += tileExists(both) ? [both] : resImp
            }
        }
        // Unciv getOwnedTileImageLocation: an era-specific image for a tile with a city
        if let era = cityEra {
            out = out.map { tileExists("\($0)-\(era)") ? "\($0)-\(era)" : $0 }
        }
        return out
    }
}
