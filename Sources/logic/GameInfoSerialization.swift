// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Compression

/// Unciv save-file compatibility (UncivFiles / FileConversions): reads and writes Unciv's GameInfo JSON,
/// plain or gzip+base64, so games can move between Epochs and Unciv (Android/desktop).
enum UncivSave {
    enum ImportError: LocalizedError {
        case notUnciv, badData(String)
        var errorDescription: String? { switch self { case .notUnciv: return "Not an Unciv save."; case .badData(let m): return "Unciv save: \(m)" } }
    }
    static let compatibilityNumber = 4
    static let createdWith = ["text": "4.19.0", "number": 1102] as [String: Any]

    // MARK: - gzip + base64 (Unciv FileConversions)

    static func decodeToJSONData(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        if trimmed.hasPrefix("{") { return trimmed.data(using: .utf8) }
        guard let raw = Data(base64Encoded: trimmed), let unzipped = gunzip(raw) else { return nil }
        return unzipped
    }
    static func encode(_ json: Data, zipped: Bool) -> String {
        zipped ? gzip(json).base64EncodedString() : (String(data: json, encoding: .utf8) ?? "")
    }
    static func isUncivSave(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        if text.hasPrefix("{") { return (text.contains("\"tileMap\"") || text.contains("\"civilizations\"")) && !text.contains("\"settings\"") }
        return text.hasPrefix("H4sI")   // base64 of the gzip magic 1f 8b 08
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
    private static func deflateRaw(_ input: Data, encode: Bool) -> Data? {
        var output = Data()
        let bufSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize); defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst; stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: bufSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { return output }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
        }
    }
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(deflateRaw(data, encode: true) ?? Data())
        var crc = crc32(data).littleEndian; withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian; withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let flags = data[data.startIndex + 3]
        var idx = data.startIndex + 10
        if flags & 0x04 != 0 { let xlen = Int(data[idx]) | Int(data[idx + 1]) << 8; idx += 2 + xlen }
        if flags & 0x08 != 0 { while idx < data.endIndex && data[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x10 != 0 { while idx < data.endIndex && data[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x02 != 0 { idx += 2 }
        guard idx < data.endIndex - 8 else { return nil }
        return deflateRaw(data[idx..<(data.endIndex - 8)], encode: false)
    }

    // MARK: - coordinates (Unciv HexMath: column = y − x, latitude = x + y)

    /// Unciv's odd columns sit half a row *up*, ours half a row *down*: mapping through a vertical mirror keeps the picture
    /// oriented like Unciv (north up) and, being a lattice isometry, keeps every adjacency.
    struct Frame {
        var minColumn = 0, minRow = 0, maxRow = 0, extraColumn = 0
        func ours(x: Int, y: Int) -> (col: Int, row: Int) {
            let column = y - x, twoRows = x + y
            let row = (twoRows - (abs(column) % 2 == 1 ? 1 : 0)) / 2
            return (column - minColumn + extraColumn, maxRow + 1 - row - (abs(column) % 2 == 1 ? 1 : 0))
        }
        func unciv(col: Int, row: Int) -> (x: Int, y: Int) {
            let column = col + minColumn - extraColumn
            let r = maxRow + 1 - row - (abs(column) % 2 == 1 ? 1 : 0)
            let twoRows = r * 2 + (abs(column) % 2 == 1 ? 1 : 0)
            return ((twoRows - column) / 2, (twoRows + column) / 2)
        }
        /// Frame for a map of ours (export): same even column shift as the import frame above, so that
        /// `unciv(col:row:)` here inverts `ours(x:y:)` there - GameState.uncivPosition relies on it.
        static func forExport(width: Int, height: Int) -> Frame {
            var f = Frame()
            f.minColumn = -(width / 2)
            f.extraColumn = (-f.minColumn) % 2 == 0 ? 0 : 1
            // Unciv's rectangular maps span rows -height/2 ... (height-1)/2; the import frame of such a map ends at
            // -((height-1)/2) + height - 2. With an odd height that is the same as -(height/2) + height - 2, but an even
            // height (a Small world-wrap map is 32x22) put every tile one row off, so every Unciv position was wrong.
            f.minRow = -((height - 1) / 2); f.maxRow = f.minRow + height - 2
            return f
        }
    }
    /// Bounding frame of an Unciv tile set in our offset grid, fitted so no empty rows are padded above or below.
    static func frame(for ucoords: [(Int, Int)]) -> (Frame, Int, Int)? {
        var frame = Frame()
        var minC = Int.max, maxC = Int.min, minR = Int.max, maxR = Int.min
        for (x, y) in ucoords {
            let column = y - x, twoRows = x + y
            let row = (twoRows - (abs(column) % 2 == 1 ? 1 : 0)) / 2
            minC = min(minC, column); maxC = max(maxC, column); minR = min(minR, row); maxR = max(maxR, row)
        }
        guard minC <= maxC else { return nil }
        frame.minColumn = minC; frame.minRow = minR; frame.maxRow = maxR
        // The column shift (-minColumn + extraColumn) must be EVEN: `ours` shoves the half row by the
        // parity of the Unciv column, HexCoord.fromOffset by the parity of ours, so an odd shift shoves
        // the wrong columns and breaks a third of the adjacencies (Athens claimed 3 tiles instead of 1).
        frame.extraColumn = abs(minC) % 2 == 0 ? 0 : 1
        var minOur = Int.max, maxOur = Int.min
        for (x, y) in ucoords { let o = frame.ours(x: x, y: y); minOur = min(minOur, o.row); maxOur = max(maxOur, o.row) }
        frame.maxRow -= minOur
        return (frame, maxC - minC + 1 + frame.extraColumn, maxOur - minOur + 1)
    }
    private static func pos(_ v: Any?) -> (Int, Int) {
        guard let d = v as? [String: Any] else { return (0, 0) }
        return (Int((d["x"] as? NSNumber)?.doubleValue ?? 0), Int((d["y"] as? NSNumber)?.doubleValue ?? 0))
    }
    private static func posJSON(_ p: (x: Int, y: Int)) -> [String: Any] { var d: [String: Any] = [:]; if p.x != 0 { d["x"] = p.x }; if p.y != 0 { d["y"] = p.y }; return d }

    // MARK: - import

    static func importGame(from text: String) throws -> GameState {
        guard let data = decodeToJSONData(text), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.notUnciv }
        importPressureOrders = pressureKeyOrders(data)
        importDiplomacyOrders = diplomacyKeyOrders(data)
        importSpecialistOrders = specialistKeyOrders(data)
        importSpaceshipPartOrders = spaceshipPartKeyOrders(data)
        importGreatPeopleOrders = greatPeopleKeyOrders(data)
        importModifierOrders = modifierKeyOrders(data)
        if ProcessInfo.processInfo.environment["DUMP_PORDER"] != nil { for k in importPressureOrders.keys.sorted() { print("PORDER \(k) \(importPressureOrders[k]!)") } }
        defer { importPressureOrders = [:]; importDiplomacyOrders = [:]; importSpecialistOrders = [:]; importSpaceshipPartOrders = [:]; importGreatPeopleOrders = [:]; importModifierOrders = [:] }
        return try importGame(root)
    }

    /// Unciv reads a city's `religion.pressures` Counter from the JSON object in FILE order (a LinkedHashMap), and that
    /// order breaks ties between equally followed religions. JSONSerialization drops it, so the keys are read here
    /// from the raw text, per "civIndex:cityIndex".
    static var importPressureOrders: [String: [String]] = [:]
    /// Path to a JSON value: one entry per open container - an object's current key, or an array's current index.
    enum KeyPathFrame { case object(key: String?), array(index: Int) }
    static func pressureKeyOrders(_ data: Data) -> [String: [String]] {
        keyOrders(data) { stack in
            // the PARENTS of a key inside civilizations[i].cities[j].religion.pressures:
            // {root, key civilizations} [i] {civ, key cities} [j] {city, key religion} {religion, key pressures}
            guard stack.count == 6,
                  case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "cities", case .array(let cj) = stack[3],
                  case .object(let k4) = stack[4], k4 == "religion", case .object(let k5) = stack[5], k5 == "pressures" else { return nil }
            return "\(ci):\(cj)"
        }
    }
    /// Unciv's `population.specialistAllocations` is a Counter (a LinkedHashMap) read in FILE order; the order is the
    /// order the kinds were first allocated (unassignExtraPopulation's ties, the great person counter's first
    /// meetings), so the keys are read here per "civIndex:cityIndex", as the pressures are.
    static var importSpecialistOrders: [String: [String]] = [:]
    static func specialistKeyOrders(_ data: Data) -> [String: [String]] {
        keyOrders(data) { stack in
            // {root, key civilizations} [i] {civ, key cities} [j] {city, key population} {population, key specialistAllocations}
            guard stack.count == 6,
                  case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "cities", case .array(let cj) = stack[3],
                  case .object(let k4) = stack[4], k4 == "population", case .object(let k5) = stack[5], k5 == "specialistAllocations" else { return nil }
            return "\(ci):\(cj)"
        }
    }
    /// Unciv's DiplomacyManager.diplomaticModifiers (a HashMap) in FILE order - its own walk, so within a bucket the order
    /// the modifiers were put in - per "civIndex:otherCivKey"
    static var importModifierOrders: [String: [String]] = [:]
    static func modifierKeyOrders(_ data: Data) -> [String: [String]] {
        keyOrders(data) { stack in
            // {root, key civilizations} [i] {civ, key diplomacy} {diplomacy, key <other>} {manager, key diplomaticModifiers}
            guard stack.count == 5, case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "diplomacy", case .object(let k3) = stack[3], let other = k3,
                  case .object(let k4) = stack[4], k4 == "diplomaticModifiers" else { return nil }
            return "\(ci):\(other)"
        }
    }
    /// Unciv's `civ.diplomacy` is a HashMap written in its own walk: bucket by bucket, and inside a bucket in the order
    /// the civs were met. JSONSerialization drops that order; the keys are read here per civilization index, so the
    /// met order - which breaks ties between civs in the same bucket - survives the import.
    static var importDiplomacyOrders: [String: [String]] = [:]
    static func diplomacyKeyOrders(_ data: Data) -> [String: [String]] {
        keyOrders(data) { stack in
            guard stack.count == 3, case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "diplomacy" else { return nil }
            return "\(ci)"
        }
    }
    /// Unciv's `victoryManager.currentsSpaceshipParts` is a Counter (LinkedHashMap) read in FILE order - the order the
    /// parts were first added, which the victory screen lists them in. Per civilization index; the extra pass over
    /// the text only runs when some civ has a part in its capital.
    static var importSpaceshipPartOrders: [String: [String]] = [:]
    static func spaceshipPartKeyOrders(_ data: Data) -> [String: [String]] {
        guard hasNonEmptyObject(data, key: "currentsSpaceshipParts") else { return [:] }
        return keyOrders(data) { stack in
            guard stack.count == 4, case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "victoryManager", case .object(let k3) = stack[3], k3 == "currentsSpaceshipParts" else { return nil }
            return "\(ci)"
        }
    }
    /// Unciv's GreatPersonManager.greatPersonPointsCounter and greatGeneralPointsCounter are Counters (LinkedHashMaps)
    /// read in FILE order - the order each great person first gained points (a key that fell to 0 and came back goes
    /// last), which getNewGreatPerson walks: of two great people of one pool crossing the threshold on the same turn,
    /// the first in it is born. JSONSerialization drops that order; the keys are read here per "civIndex:counter".
    static var importGreatPeopleOrders: [String: [String]] = [:]
    static func greatPeopleKeyOrders(_ data: Data) -> [String: [String]] {
        guard hasNonEmptyObject(data, key: "greatPersonPointsCounter") || hasNonEmptyObject(data, key: "greatGeneralPointsCounter") else { return [:] }
        return keyOrders(data) { stack in
            // {root, key civilizations} [i] {civ, key greatPeople} {greatPeople, key greatPersonPointsCounter / greatGeneralPointsCounter}
            guard stack.count == 4, case .object(let k0) = stack[0], k0 == "civilizations", case .array(let ci) = stack[1],
                  case .object(let k2) = stack[2], k2 == "greatPeople", case .object(let k3?) = stack[3],
                  k3 == "greatPersonPointsCounter" || k3 == "greatGeneralPointsCounter" else { return nil }
            return "\(ci):\(k3)"
        }
    }
    /// Whether the text holds `"key": {"...` - an object under that key with at least one entry.
    static func hasNonEmptyObject(_ data: Data, key: String) -> Bool {
        let needle = Data("\"\(key)\"".utf8)
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            var i = r.upperBound
            func skipSpace() { while i < data.endIndex, data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09 { i += 1 } }
            skipSpace()
            if i < data.endIndex, data[i] == 0x3A {   // :
                i += 1; skipSpace()
                if i < data.endIndex, data[i] == 0x7B {   // {
                    i += 1; skipSpace()
                    if i < data.endIndex, data[i] == 0x22 { return true }   // a first key
                }
            }
            from = r.upperBound
        }
        return false
    }
    /// The keys, in file order, of every object whose parent path `match` names.
    static func keyOrders(_ data: Data, match: ([KeyPathFrame]) -> String?) -> [String: [String]] {
        let b = [UInt8](data); var i = 0
        var out: [String: [String]] = [:]
        typealias Frame = KeyPathFrame
        var stack: [Frame] = []
        func readString() -> String {
            i += 1; var bytes: [UInt8] = []
            while i < b.count && b[i] != 0x22 {
                if b[i] == 0x5C { bytes.append(b[i]); i += 1 }   // keep the escape and the next byte
                bytes.append(b[i]); i += 1
            }
            i += 1
            let raw = String(decoding: bytes, as: UTF8.self)
            return (try? JSONSerialization.jsonObject(with: Data(("\"" + raw + "\"").utf8), options: .fragmentsAllowed) as? String) ?? raw
        }
        var expectKey = false
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x7B: stack.append(.object(key: nil)); expectKey = true; i += 1
            case 0x5B: stack.append(.array(index: 0)); i += 1
            case 0x7D, 0x5D: _ = stack.popLast(); expectKey = false; i += 1
            case 0x2C:
                if case .array(let n)? = stack.last { stack[stack.count - 1] = .array(index: n + 1) } else { expectKey = true }
                i += 1
            case 0x22:
                let str = readString()
                if expectKey, case .object? = stack.last {
                    if let p = match(Array(stack.dropLast())) { out[p, default: []].append(str) }   // a key of a matched object
                    stack[stack.count - 1] = .object(key: str)
                    expectKey = false
                }
            default: i += 1
            }
        }
        return out
    }
    static func importGame(_ root: [String: Any]) throws -> GameState {
        guard let tileMap = root["tileMap"] as? [String: Any], let tileList = tileMap["tileList"] as? [[String: Any]], let civsJSON = root["civilizations"] as? [[String: Any]] else { throw ImportError.notUnciv }
        let params = root["gameParameters"] as? [String: Any] ?? [:]
        let mapParams = tileMap["mapParameters"] as? [String: Any] ?? [:]
        let mods = (params["mods"] as? [String]) ?? []
        let savedStarts = tileMap["startingLocations"] as? [[String: Any]] ?? []
        let mapDescription = (tileMap["description"] as? String) ?? ""
        // Unciv GameParameters.baseRuleset (+ convertOldSavesToNewSaves: a base ruleset may still hide in the mod list)
        let savedBaseRuleset = (params["baseRuleset"] as? String) ?? (mapParams["baseRuleset"] as? String) ?? Ruleset.baseRulesetName
        let importedBaseRuleset = Ruleset.baseRulesets.contains(savedBaseRuleset) ? savedBaseRuleset
            : (mods.first { Ruleset.baseRulesets.contains($0) } ?? Ruleset.baseRulesetName)
        Ruleset.activate(mods: mods.filter { $0 != importedBaseRuleset && Ruleset.availableMods().contains($0) }, baseRuleset: importedBaseRuleset)
        let rs = Ruleset.shared

        // Map frame
        let ucoords: [(Int, Int)] = tileList.map { pos($0["position"]) }
        guard let (frame, width, height) = frame(for: ucoords) else { throw ImportError.badData("empty map") }
        let wrap = (mapParams["worldWrap"] as? Bool) ?? false
        var tiles: [Tile] = []
        for row in 0..<height { for col in 0..<width { tiles.append(Tile(coord: HexCoord.fromOffset(col: col, row: row), baseTerrain: "Ocean")) } }
        var map = GameMap(width: width, height: height, tiles: tiles, wrapX: wrap && frame.extraColumn == 0)
        HexCoord.wrapWidth = map.wrapX ? width : nil

        // Settings
        var s = GameSettings()
        s.players = []
        // Unciv GameInfo.difficulty (`var difficulty = "Chieftain"`, left out of the save when it is that) is what
        // setGlobalTransients makes difficultyObject - every getDifficulty() - from; gameParameters.difficulty (default
        // "Prince") is the new game's choice, which only ConditionalDifficulty reads. A save without the field is Chieftain.
        s.difficulty = (root["difficulty"] as? String) ?? "Chieftain"
        s.speed = (params["speed"] as? String) ?? "Quick"   // Unciv Speed.DEFAULT
        // Unciv GameParameters.victoryTypes defaults to an EMPTY list, and the save leaves a field out when it
        // equals its default: no key is no victory enabled, and every AI then plays for "Neutral"
        // (getPreferredVictoryTypes). Filling in all of them gave Greece "Diplomatic" and +5 on Patronage.
        s.victoryTypes = Set((params["victoryTypes"] as? [String]) ?? [])
        s.barbarians = !((params["noBarbarians"] as? Bool) ?? false)
        s.ragingBarbarians = (params["ragingBarbarians"] as? Bool) ?? false
        s.oneCityChallenge = (params["oneCityChallenge"] as? Bool) ?? false
        s.noCityRazing = (params["noCityRazing"] as? Bool) ?? false
        s.nuclearWeaponsEnabled = (params["nuclearWeaponsEnabled"] as? Bool) ?? true
        s.espionageEnabled = (params["espionageEnabled"] as? Bool) ?? false
        s.noStartBias = (params["noStartBias"] as? Bool) ?? false
        // the new-game fields Unciv keeps in gameParameters as they were set up (GameParameters.kt:11-34 defaults), which
        // GameSetupInfo(gameInfo) hands to Start new game
        s.shufflePlayerOrder = (params["shufflePlayerOrder"] as? Bool) ?? false
        s.cityStateCount = (params["numberOfCityStates"] as? Int) ?? 6
        s.randomNumberOfPlayers = (params["randomNumberOfPlayers"] as? Bool) ?? false
        s.minNumberOfPlayers = (params["minNumberOfPlayers"] as? Int) ?? 3
        s.maxNumberOfPlayers = (params["maxNumberOfPlayers"] as? Int) ?? 3
        s.randomNumberOfCityStates = (params["randomNumberOfCityStates"] as? Bool) ?? false
        s.minNumberOfCityStates = (params["minNumberOfCityStates"] as? Int) ?? 6
        s.maxNumberOfCityStates = (params["maxNumberOfCityStates"] as? Int) ?? 6
        s.enableRandomNationsPool = (params["enableRandomNationsPool"] as? Bool) ?? false
        s.randomNationsPool = (params["randomNationsPool"] as? [String]) ?? []
        s.godMode = (params["godMode"] as? Bool) ?? false
        s.anyoneCanSpectate = (params["anyoneCanSpectate"] as? Bool) ?? true
        s.startingEra = (params["startingEra"] as? String) ?? "Ancient era"   // Unciv GameParameters.startingEra
        // Unciv GameInfo.isReligionEnabled is derived, not stored - so it survives a save either way. It has to
        // be settled after startingEra, which it reads.
        s.religionEnabled = !(rs.era(named: s.startingEra)?.uniques.contains("Starting in this era disables religion") ?? false)
            && !rs.modOptionUniques.contains { $0.pattern == "Disable religion" }
        s.maxTurns = (params["maxTurns"] as? Int) ?? 500
        s.mapType = MapGenerator.canonicalType((mapParams["type"] as? String) ?? "Pangaea")
        let importedShape = (mapParams["shape"] as? String) ?? "Hexagonal"   // Unciv MapParameters.shape = MapShape.hexagonal by default, so libGDX omits it on hexagonal maps
        s.mapShape = ["Hexagonal", "Flat Earth Hexagonal"].contains(importedShape) ? importedShape : "Rectangular"   // Unciv MapShape
        s.worldWrap = map.wrapX
        s.ancientRuins = !((mapParams["noRuins"] as? Bool) ?? false)
        s.naturalWonders = !((mapParams["noNaturalWonders"] as? Bool) ?? false)
        // the rest of Unciv's MapParameters, with its defaults where libGDX left a default out
        s.resourceSetting = (mapParams["mapResources"] as? String) ?? "Default"
        s.strategicBalance = (mapParams["strategicBalance"] as? Bool) ?? false
        s.legendaryStart = (mapParams["legendaryStart"] as? Bool) ?? false
        func num(_ k: String, _ d: Double) -> Double { (mapParams[k] as? NSNumber)?.doubleValue ?? d }
        s.tilesPerBiomeArea = (mapParams["tilesPerBiomeArea"] as? NSNumber)?.intValue ?? 6
        s.maxCoastExtension = (mapParams["maxCoastExtension"] as? NSNumber)?.intValue ?? 3
        s.elevationExponent = num("elevationExponent", 0.7); s.temperatureIntensity = num("temperatureintensity", 0.6)
        s.vegetationRichness = num("vegetationRichness", 0.4); s.rareFeaturesRichness = num("rareFeaturesRichness", 0.05)
        s.waterThreshold = num("waterThreshold", 0); s.temperatureShift = num("temperatureShift", 0)
        s.mapWidth = width; s.mapHeight = height; s.mapSizeName = "Custom"
        if let size = mapParams["mapSize"] as? [String: Any] {
            let r = (size["radius"] as? Int) ?? 0, w = (size["width"] as? Int) ?? 0, h = (size["height"] as? Int) ?? 0
            s.uncivNumberOfTiles = s.mapShape == "Rectangular" ? w * h : 1 + 3 * r * (r - 1)   // Unciv MapParameters.numberOfTiles
            // Unciv tileMap.mapParameters.mapSize and shape, which our grid (one row taller, empty corners) does not tell
            map.uncivSize = UncivMapSize(name: (size["name"] as? String) ?? "", radius: r, width: w, height: h, shape: s.mapShape)
        }
        s.mapDescription = mapDescription
        s.seed = UInt64(truncatingIfNeeded: (mapParams["seed"] as? Int) ?? 0)
        s.gameId = root["gameId"] as? String
        s.mods = mods.filter { $0 != importedBaseRuleset }
        s.baseRuleset = importedBaseRuleset
        if let players = params["players"] as? [[String: Any]] { s.players = players.map { PlayerSetup(chosenCiv: ($0["chosenCiv"] as? String) ?? "Random", isHuman: ($0["playerType"] as? String) == "Human") } }

        let state = GameState(settings: s, map: map, rng: SeededRandom(seed: s.seed == 0 ? 42 : s.seed))
        state.turn = ((root["turns"] as? Int) ?? 0) + 1   // Unciv counts turns from 0, we count from 1
        state.currentTurnStartTime = ((root["currentTurnStartTime"] as? NSNumber)?.doubleValue) ?? 0

        // Civilizations
        var civIdByKey: [String: Int] = [:]
        var pendingSpyCoords: [Int: HexCoord] = [:]
        for (civIndexInSave, cj) in civsJSON.enumerated() {
            let name = (cj["civName"] as? String) ?? "Unknown"
            let key = (cj["civID"] as? String) ?? name
            let isHuman = (cj["playerType"] as? String) == "Human"
            var civ = Civilization(id: state.newId(), nation: name, isPlayer: isHuman)
            civIdByKey[key] = civ.id; civIdByKey[name] = civ.id
            civ.isBarbarian = name == "Barbarians"
            if let n = rs.nations[name], n.isCityState { civ.isCityState = true; civ.cityStateType = n.cityStateType }
            civ.gold = Double((cj["gold"] as? NSNumber)?.doubleValue ?? 0)
            civ.playerUserId = (cj["playerId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            civ.playerMinutesBeforeForceResign = (cj["playerMinutesBeforeForceResign"] as? NSNumber)?.intValue ?? 3 * 24 * 60   // Kotlin field default
            civ.totalTurnTimeSeconds = (cj["totalTurnTimeSeconds"] as? NSNumber)?.intValue ?? 0   // Kotlin field defaults
            civ.turnsPlayedAsHuman = (cj["turnsPlayedAsHuman"] as? NSNumber)?.intValue ?? 0
            // Unciv Civilization.exploredRegion: its topLeft / bottomRight Vector2s, a zero coordinate left out
            if let er = cj["exploredRegion"] as? [String: Any] {
                func point(_ v: Any?) -> ExploredRegion.Point {
                    let d = v as? [String: Any]
                    return ExploredRegion.Point(x: (d?["x"] as? NSNumber)?.floatValue ?? 0, y: (d?["y"] as? NSNumber)?.floatValue ?? 0)
                }
                civ.exploredRegion = ExploredRegion(topLeft: point(er["topLeft"]), bottomRight: point(er["bottomRight"]))
            }
            if let tech = cj["tech"] as? [String: Any] {
                civ.techs = Set((tech["techsResearched"] as? [String]) ?? [])
                civ.techUniqueOrder = javaHashMapOrder(Array(NSOrderedSet(array: (tech["techsResearched"] as? [String]) ?? []).array as? [String] ?? []))   // Unciv TechManager.setTransients walks the HashSet
                let queue = (tech["techsToResearch"] as? [String]) ?? []
                civ.currentTech = queue.first; civ.techQueue = Array(queue.dropFirst())
                civ.freeTechs = (tech["freeTechs"] as? Int) ?? 0; civ.scienceFromResearchAgreements = Double((tech["scienceFromResearchAgreements"] as? Int) ?? 0)
                civ.futureTechs = (tech["repeatingTechsResearched"] as? Int) ?? 0
                if let prog = tech["techsInProgress"] as? [String: Any] { for (name, v) in prog { if let n = v as? NSNumber { civ.techsInProgress[name] = n.intValue } } }
                civ.overflowScience = (tech["overflowScience"] as? Int) ?? 0
                if let last8 = tech["scienceOfLast8Turns"] as? [Int], last8.count == 8 { civ.scienceOfLast8Turns = last8 }
                if let g = (tech["goldPercentConvertedToScience"] as? NSNumber)?.doubleValue { civ.goldPercentConvertedToScience = g }
            }
            if let temps = cj["temporaryUniques"] as? [[String: Any]] {
                civ.temporaryUniques = temps.compactMap { tu in (tu["unique"] as? String).map { TemporaryUnique(unique: $0, turnsLeft: (tu["turnsLeft"] as? Int) ?? 0, sourceObjectName: tu["sourceObjectName"] as? String, sourceObjectType: tu["sourceObjectType"] as? String) } }
            }
            if let pol = cj["policies"] as? [String: Any] {
                let adopted = (pol["adoptedPolicies"] as? [String]) ?? []
                // Unciv puts every PolicyBranch into ruleset.policies too, so an adopted branch name is a
                // policy: keep it in civ.policies (adoptedPolicyCount, "after adopting [branch]" and the
                // adopted-policy countables all read this set), not only in openBranches.
                civ.policies = Set(adopted.filter { p in rs.policies[p] != nil || rs.policyBranches.contains { $0.name == p } })
                civ.openBranches = Set(adopted.filter { p in rs.policyBranches.contains { $0.name == p } })
                civ.policyUniqueOrder = javaHashMapOrder(Array(NSOrderedSet(array: adopted.filter { civ.policies.contains($0) }).array as? [String] ?? []))   // Unciv PolicyManager.setTransients walks the HashSet
                civ.freePolicies = (pol["freePolicies"] as? Int) ?? 0
                civ.cultureStored = Double((pol["storedCulture"] as? NSNumber)?.doubleValue ?? 0)
                civ.numberOfAdoptedPolicies = (pol["numberOfAdoptedPolicies"] as? Int) ?? 0   // Unciv PolicyManager.numberOfAdoptedPolicies defaults to 0, so an absent field means 0 - not "unknown"
                civ.shouldOpenPolicyPicker = (pol["shouldOpenPolicyPicker"] as? Bool) ?? false
                if let c8 = pol["cultureOfLast8Turns"] as? [Int], c8.count == 8 { civ.cultureOfLast8Turns = c8 }
            }
            if let lsi = cj["lastSeenImprovement"] as? [String: Any] {   // Unciv LastSeenImprovement.read: "(x,y)" → improvement name
                for (k, v) in lsi {
                    let parts = k.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard parts.count == 2, let name = (v as? String) ?? ((v as? [String: Any])?["value"] as? String) else { continue }
                    let o = frame.ours(x: Int(parts[0]), y: Int(parts[1]))
                    civ.lastSeenImprovement[HexCoord.fromOffset(col: o.col, row: o.row)] = name
                }
            }
            if let atk = cj["attacksSinceTurnStart"] as? [[String: Any]] {   // Unciv Civilization.attacksSinceTurnStart (attack arrows)
                civ.attacksSinceTurnStart = atk.map { a in
                    let (sx, sy) = pos(a["source"]), (tx, ty) = pos(a["target"])
                    let so = frame.ours(x: sx, y: sy), to = frame.ours(x: tx, y: ty)
                    return HistoricalAttackMemory(attackingUnit: a["attackingUnit"] as? String, source: HexCoord.fromOffset(col: so.col, row: so.row), target: HexCoord.fromOffset(col: to.col, row: to.row))
                }
            }
            if let alerts = cj["popupAlerts"] as? [[String: Any]] {   // Unciv Civilization.popupAlerts
                civ.popupAlerts = alerts.compactMap { a in (a["type"] as? String).flatMap { AlertType(rawValue: $0) }.map { PopupAlert(type: $0, value: (a["value"] as? String) ?? "") } }
            }
            if let ga = cj["goldenAges"] as? [String: Any] {
                civ.goldenAgePoints = Double((ga["storedHappiness"] as? NSNumber)?.doubleValue ?? 0)
                civ.goldenAgeTurns = (ga["turnsLeftForCurrentGoldenAge"] as? Int) ?? 0
                civ.goldenAgesHad = (ga["numberOfGoldenAges"] as? Int) ?? 0
            }
            if let gp = cj["greatPeople"] as? [String: Any] {
                civ.mayaLimitedFreeGP = (gp["mayaLimitedFreeGP"] as? Int) ?? 0
                civ.longCountGPPool = (gp["longCountGPPool"] as? [String]) ?? []
                // Unciv Counter.read: `if (entry.isValue) entry.asInt() else entry.getInt("value")`, and Counter.put drops a 0
                func counterValue(_ v: Any) -> Int? { (v as? NSNumber)?.intValue ?? ((v as? [String: Any])?["value"] as? NSNumber)?.intValue }
                for (k, v) in (gp["greatPersonPointsCounter"] as? [String: Any]) ?? [:] { if let n = counterValue(v), n != 0 { civ.greatPersonPoints[k] = Double(n) } }
                for (k, v) in (gp["pointsForNextGreatPersonCounter"] as? [String: Any]) ?? [:] { if let n = (v as? NSNumber)?.intValue { civ.pointsForNextGreatPersonCounter[k] = n } }
                for (k, v) in (gp["pointsForNextGreatGeneralCounter"] as? [String: Any]) ?? [:] { if let n = (v as? NSNumber)?.intValue { civ.pointsForNextGreatGeneralCounter[k] = n } }
                for (k, v) in (gp["greatGeneralPointsCounter"] as? [String: Any]) ?? [:] { if let n = counterValue(v), n != 0 { civ.greatGeneralPoints[k] = n } }
                // The two Counters' file order (spawnGreatPeople walks it; a key it lacks - importGame(root) called on its
                // own - follows by name). Ours left both orders empty, so an imported game's great people were checked
                // alphabetically, and after any newer key, for the rest of the game.
                civ.greatPersonOrder = (importGreatPeopleOrders["\(civIndexInSave):greatPersonPointsCounter"] ?? []).filter { civ.greatPersonPoints[$0] != nil }
                civ.greatGeneralOrder = (importGreatPeopleOrders["\(civIndexInSave):greatGeneralPointsCounter"] ?? []).filter { civ.greatGeneralPoints[$0] != nil }
                civ.freeGreatPeople = (gp["freeGreatPeople"] as? Int) ?? 0
            }
            if let rel = cj["religionManager"] as? [String: Any] {
                civ.faithStored = Double((rel["storedFaith"] as? NSNumber)?.doubleValue ?? 0)
                let stateName = (rel["religionState"] as? String) ?? "None"
                if let fb = rel["freeBeliefs"] as? [String: Any] { for (k, v) in fb { if let n = (v as? NSNumber)?.intValue, n != 0 { civ.freeBeliefsByType[k] = n } } }
                // Unciv ReligionManager.religion is transient: the real entries live in GameInfo.religions (pantheons are named after their belief)
                let founded = ((root["religions"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? [String: Any] }.filter { ($0["foundingCivName"] as? String) == (cj["civName"] as? String) }
                let isReligionState = ["Religion", "EnhancedReligion", "EnhancingReligion"].contains(stateName)
                let pantheonEntry = founded.first { rs.beliefs[($0["name"] as? String) ?? ""]?.type == "Pantheon" }
                let religionEntry = founded.first { rs.beliefs[($0["name"] as? String) ?? ""] == nil }
                if let r = (rel["religion"] as? [String: Any]) ?? (isReligionState ? religionEntry : pantheonEntry) ?? founded.first {
                    let beliefs = ((r["founderBeliefs"] as? [String]) ?? []) + ((r["followerBeliefs"] as? [String]) ?? [])
                    let pantheons = beliefs.filter { rs.beliefs[$0]?.type == "Pantheon" }
                    civ.pantheonBelief = pantheons.first
                    if stateName == "Religion" || stateName == "EnhancedReligion" || stateName == "EnhancingReligion" {
                        civ.religionName = (r["name"] as? String)
                        civ.religionDisplayName = (r["displayName"] as? String).flatMap { $0 == (r["name"] as? String) ? nil : $0 }   // Unciv Religion.displayName
                        civ.religionBeliefs = beliefs   // pantheon beliefs stay part of the religion (Religion.followerBeliefs)
                        civ.religionEnhanced = stateName == "EnhancedReligion"
                    } else {
                        civ.religionBeliefs = Array(pantheons.dropFirst())   // expanded pantheon
                    }
                }
            }
            if let vm = cj["victoryManager"] as? [String: Any], let parts = vm["currentsSpaceshipParts"] as? [String: Any] {
                for (k, v) in parts { civ.spaceshipParts[k] = (v as? NSNumber)?.intValue ?? 0 }
                civ.spaceshipPartOrder = (importSpaceshipPartOrders["\(civIndexInSave)"] ?? []).filter { parts[$0] != nil }   // the Counter's file order
            }
            if let vm = cj["victoryManager"] as? [String: Any], let won = vm["hasEverWonDiplomaticVote"] as? Bool { civ.hasEverWonDiplomaticVote = won }
            if let rm = cj["ruinsManager"] as? [String: Any], let lastRewards = rm["lastChosenRewards"] as? [String], lastRewards.count == 2 { civ.lastRuinRewards = lastRewards }
            civ.seenNaturalWonders = Set((cj["naturalWonders"] as? [String]) ?? [])
            civ.citiesCreated = (cj["citiesCreated"] as? Int) ?? 0
            civ.hasEverOwnedOriginalCapital = (cj["hasEverOwnedOriginalCapital"] as? Bool) ?? false
            civ.resourceStockpiles = (cj["resourceStockpiles"] as? [String: Int]) ?? [:]
            if let title = cj["leaderTitle"] as? String, !title.isEmpty { civ.leaderTitle = title }
            /// Unciv NotificationAction subclasses, read back from the save.
            func decodeNotificationActions(_ raw: Any?) -> [NotificationAction] {
                var meta = NotificationMeta()
                for a in raw as? [[String: Any]] ?? [] {
                        func coord(_ v: Any?) -> HexCoord { let (x, y) = pos(v); let o = frame.ours(x: x, y: y); return HexCoord.fromOffset(col: o.col, row: o.row) }
                        if let d = a["LocationAction"] as? [String: Any] { meta.actions.append(.location(coord(d["location"]))) }
                        else if let d = a["CityAction"] as? [String: Any] { meta.actions.append(.city(coord(d["city"]))) }
                        else if let d = a["TechAction"] as? [String: Any] { meta.actions.append(.tech(d["techName"] as? String ?? "")) }
                        else if let d = a["DiplomacyAction"] as? [String: Any] {
                            let name = d["otherCivName"] as? String ?? ""
                            meta.actions.append(d["showTrade"] as? Bool == true ? .diplomacyTrade(name) : .diplomacy(name))
                        }
                        else if let d = a["MapUnitAction"] as? [String: Any] { meta.actions.append(.unit(coord(d["location"]), (d["id"] as? NSNumber)?.intValue ?? -1)) }
                        else if let d = a["CivilopediaAction"] as? [String: Any] { meta.actions.append(.civilopedia(d["link"] as? String ?? "")) }
                        else if let d = a["OverviewAction"] as? [String: Any] { meta.actions.append(.overview(d["page"] as? String ?? "Resources", d["select"] as? String ?? "")) }
                        else if let d = a["PolicyAction"] as? [String: Any] { meta.actions.append(.policy(d["select"] as? String ?? "")) }
                        else if a["EspionageAction"] != nil { meta.actions.append(.espionage) }
                        else if let d = a["ReligionAction"] as? [String: Any] { meta.actions.append(.religion(d["religionName"] as? String ?? "")) }
                        else if let d = a["LinkAction"] as? [String: Any] { meta.actions.append(.link(d["url"] as? String ?? "")) }
                        else if let d = a["PromoteUnitAction"] as? [String: Any] { meta.actions.append(.promoteUnit(d["name"] as? String ?? "", coord(d["location"]), (d["id"] as? NSNumber)?.intValue ?? -1)) }
                        else if a["MayaLongCountAction"] != nil { meta.actions.append(.mayaLongCount) }
                }
                return meta.actions
            }
            for turnEntry in (cj["notificationsLog"] as? [[String: Any]]) ?? [] {
                let t = ((turnEntry["turn"] as? Int) ?? 0) + 1   // Unciv stamps gameInfo.turns (zero-based)
                var entry = NotificationLogEntry(turn: t)
                for n in (turnEntry["notifications"] as? [[String: Any]]) ?? [] {
                    if let text = n["text"] as? String {
                        var meta = NotificationMeta()
                        meta.category = (n["category"] as? String).flatMap { NotificationCategory(rawValue: $0) } ?? .General
                        meta.icons = (n["icons"] as? [String]) ?? []
                        meta.actions = decodeNotificationActions(n["actions"])
                        entry.texts.append(text); entry.meta.append(meta)
                    }
                }
                if !entry.texts.isEmpty { civ.notificationLog.append(entry) }
            }
            civ.totalCultureForContests = (cj["totalCultureForContests"] as? Int) ?? 0
            civ.totalFaithForContests = (cj["totalFaithForContests"] as? Int) ?? 0
            civ.numMinorCivsAttacked = (cj["numMinorCivsAttacked"] as? Int) ?? 0
            if let cc = cj["civConstructions"] as? [String: Any] {
                for (k, v) in (cc["boughtItemsWithIncreasingPrice"] as? [String: Any]) ?? [:] { if let n = (v as? NSNumber)?.intValue { civ.boughtWithIncreasingPrice[k] = n } }
                for (k, v) in (cc["builtItemsWithIncreasingCost"] as? [String: Any]) ?? [:] { if let n = (v as? NSNumber)?.intValue { civ.builtItemsWithIncreasingCost[k] = n } }
            }
            if let p = cj["cityStatePersonality"] as? String { civ.cityStatePersonality = p }
            if let u = cj["cityStateUniqueUnit"] as? String, !u.isEmpty { civ.cityStateUniqueUnit = u }
            if let r = cj["cityStateResource"] as? String, !r.isEmpty { civ.cityStateResource = r }
            if let notes = cj["notifications"] as? [[String: Any]] {
                civ.notifications = []; civ.notificationCoords = []; civ.notificationMeta = []
                for n in notes {
                    guard let text = n["text"] as? String else { continue }
                    var meta = NotificationMeta()
                    meta.category = NotificationCategory(rawValue: n["category"] as? String ?? "General") ?? .General
                    meta.icons = n["icons"] as? [String] ?? []
                    meta.actions = decodeNotificationActions(n["actions"])
                    civ.notifications.append(text)
                    civ.notificationCoords.append(meta.actions.compactMap { if case .location(let c) = $0 { return c }; return nil }.first)
                    civ.notificationMeta.append(meta)
                }
            }
            if let history = cj["statsHistory"] as? [String: Any] {
                let ids: [Character: String] = ["S": "Score", "N": "Population", "C": "Growth", "P": "Production", "G": "Gold", "T": "Territory", "F": "Force", "H": "Happiness", "W": "Technologies", "A": "Culture", "E": "Tiles Explored"]
                for (turnKey, v) in history {
                    guard let turn = Int(turnKey), let str = v as? String else { continue }
                    var row: [String: Int] = [:]; var key: Character? = nil; var num = ""
                    for ch in str + "S" {
                        if ch.isNumber || (ch == "-" && num.isEmpty) { num.append(ch) }
                        else { if let k = key, let name = ids[k], let n = Int(num) { row[name] = n }; key = ch; num = "" }
                    }
                    civ.statsHistory[turn] = row
                }
            }
            if let esp = cj["espionageManager"] as? [String: Any] {
                civ.spiesGranted = Set((esp["erasSpyEarnedFor"] as? [String]) ?? [])
                civ.dismissedShouldMoveSpies = (esp["dismissedShouldMoveSpies"] as? Bool) ?? false
                for sj in (esp["spyList"] as? [[String: Any]]) ?? [] {
                    var spy = Spy(id: state.newId(), name: (sj["name"] as? String) ?? "Spy")
                    spy.rank = (sj["rank"] as? Int) ?? 1
                    let action = (sj["action"] as? String) ?? "None"
                    spy.alive = action != "Dead"
                    spy.arriving = ["Moving", "EstablishNetwork"].contains(action) ? ((sj["turnsRemainingForAction"] as? Int) ?? 0) : 0
                    spy.progress = Double((sj["progressTowardsStealingTech"] as? NSNumber)?.doubleValue ?? 0)
                    spy.action = action; spy.turnsRemaining = (sj["turnsRemainingForAction"] as? Int) ?? 0
                    if let loc = sj["location"] as? [String: Any] { let (lx, ly) = pos(loc); let lo = frame.ours(x: lx, y: ly); pendingSpyCoords[spy.id] = HexCoord.fromOffset(col: lo.col, row: lo.row) }
                    civ.spies.append(spy)
                }
            }
            if let sl = savedStarts.first(where: { ($0["nation"] as? String) == civ.nation }) {
                let (sx, sy) = pos(sl["position"]); let so = frame.ours(x: sx, y: sy)
                civ.startingLocation = HexCoord.fromOffset(col: so.col, row: so.row)
            }
            state.civs.append(civ)
        }
        // Unciv Civilization.tradeRequests: the receiver stores the trade already reversed, so its "ourOffers" is
        // what the receiver would hand over - which is the proposer's "want".
        for cj in civsJSON {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            guard let toId = civIdByKey[key] else { continue }
            for rq in (cj["tradeRequests"] as? [[String: Any]]) ?? [] {
                guard let fromId = civIdByKey[(rq["requestingCiv"] as? String) ?? ""], let trade = rq["trade"] as? [String: Any] else { continue }
                var offer = TradeOffer(id: state.newId(), from: fromId, to: toId)
                offer.want = tradeSideFromJSON((trade["ourOffers"] as? [[String: Any]]) ?? [], state: state)
                offer.give = tradeSideFromJSON((trade["theirOffers"] as? [[String: Any]]) ?? [], state: state)
                offer.evTailWant = offerListOrder((trade["ourOffers"] as? [[String: Any]]) ?? [])
                offer.evTailGive = offerListOrder((trade["theirOffers"] as? [[String: Any]]) ?? [])
                offer.turnCreated = state.turn
                state.pendingOffers.append(offer)
            }
        }
        // Diplomacy (needs all ids)
        // Each civ's DiplomacyManager holds ITS OWN copy of every trade; the two copies are matched up below, so
        // each offer becomes one deal carrying both sides' durations.
        var importedTrades: [(me: Int, other: Int, trades: [[String: Any]])] = []
        // Each imported trade as a whole (Unciv DiplomacyManager.trades, our TradeRecord): its id, its civs, the offers each
        // gives, and which side's copy is already gone - made into records once the cities are read (a City offer names one)
        var importedRecords: [(id: Int, a: Int, b: Int, aOffers: [[String: Any]], bOffers: [[String: Any]], aGone: Bool, bGone: Bool)] = []
        for (civIndexInSave, cj) in civsJSON.enumerated() {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            // A civ that has met nobody has no "diplomacy" at all - its flags and quest manager below are still read
            // (a city-state's election countdown went missing, and a random one was rolled in its place).
            guard let myId = civIdByKey[key], let mi = state.civIndex(myId) else { continue }
            let diplo = (cj["diplomacy"] as? [String: Any]) ?? [:]
            // Unciv Civilization.allyCiv (a field, serialized as allyCivName)
            if state.civs[mi].isCityState, let allyKey = cj["allyCivName"] as? String, let allyId = civIdByKey[allyKey] { state.civs[mi].allySince = [allyId: state.turn] }
            // Walk the managers in the file's order: `meet` records the met order, which orders civs sharing a bucket
            let fileOrder = importDiplomacyOrders["\(civIndexInSave)"] ?? []
            let orderedKeys = fileOrder.filter { diplo[$0] != nil } + diplo.keys.filter { !fileOrder.contains($0) }.sorted()
            for otherKey in orderedKeys {
                guard let dv = diplo[otherKey] else { continue }
                guard let d = dv as? [String: Any], let otherId = civIdByKey[(d["otherCivName"] as? String) ?? otherKey] ?? civIdByKey[otherKey] else { continue }
                state.meet(mi, otherId)
                let status = (d["diplomaticStatus"] as? String) ?? "War"   // Unciv DiplomacyManager.diplomaticStatus defaults to War, so the key is absent exactly when they are at war
                if status == "War" { state.civs[mi].atWarWith.insert(otherId) }
                if status == "DefensivePact" { state.civs[mi].defensivePacts.insert(otherId) }
                if status == "Protector", state.civs[mi].isCityState, let oi = state.civIndex(otherId) { state.civs[oi].protectedCityStates.insert(myId) }   // Unciv DiplomaticStatus.Protector
                if let mods = d["diplomaticModifiers"] as? [String: Any] {
                    state.civs[mi].opinions[otherId] = mods.mapValues { ($0 as? NSNumber)?.doubleValue ?? 0 }
                    // Unciv reads the HashMap in FILE order: the file lists it bucket by bucket, each bucket in its insertion
                    // order, and the load puts the keys in that order again
                    let fileOrder = importModifierOrders["\(civIndexInSave):\(otherKey)"] ?? []
                    state.civs[mi].opinionOrder[otherId] = fileOrder.filter { mods[$0] != nil } + mods.keys.filter { !fileOrder.contains($0) }.sorted()
                }
                if let flags = d["flagsCountdown"] as? [String: Any] {
                    state.civs[mi].diploFlags[otherId] = flags.mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
                    if let f = flags["DeclarationOfFriendship"] as? NSNumber, f.intValue > 0 { state.civs[mi].friendships[otherId] = state.turn - (30 - f.intValue) }
                    if let f = flags["Denunciation"] as? NSNumber, f.intValue > 0 { state.civs[mi].denouncements[otherId] = state.turn - (30 - f.intValue) }
                    if let f = flags["PeaceTreaty"] as? NSNumber, f.intValue > 0 { state.civs[mi].peaceTreatyUntil[otherId] = state.turn + f.intValue }
                }
                if let inf = d["influence"] as? NSNumber, state.civs[mi].isCityState { state.civs[mi].influence[otherId] = inf.doubleValue }
                // hasOpenBorders is recomputed from the trades below (Unciv updateHasOpenBorders on load)
                // Unciv DiplomacyManager's no-arg constructor (the one a load goes through) starts both at
                // OLD_SAVEFILE_INITIAL_SMOOTHED_OPINION = -250f, and libGDX leaves a field equal to that out of the save
                state.civs[mi].smoothedOpinion[otherId] = (d["smoothedOpinionOfOtherCiv"] as? NSNumber)?.doubleValue ?? -250
                state.civs[mi].cachedSmoothedOpinion[otherId] = (d["cachedSmoothedOpinionOfOtherCiv"] as? NSNumber)?.doubleValue ?? -250
                if let ra = d["totalOfScienceDuringRA"] as? NSNumber { state.civs[mi].totalOfScienceDuringRA[otherId] = ra.intValue }
                let trades = (d["trades"] as? [[String: Any]]) ?? []
                // Unciv DiplomacyManager.turnsToPeaceTreaty: OUR copy's Peace Treaty offer (ourOffers) with duration > 0
                func isPeaceTreaty(_ oj: [String: Any]) -> Bool { (oj["type"] as? String) == "Treaty" && (oj["name"] as? String) == "Peace Treaty" }
                var lastTurnOfTreaty = false, remadeAtZero = false
                for tj in trades {
                    // The treaty's last turn: ourOffers at 0 and theirOffers still running, the trade kept by
                    // DiplomacyTurnManager.nextTurnTrades until this civ's next end of turn ends it ("[Peace Treaty] from
                    // [..] has ended") - read as a treaty that runs out this turn (a round later for a civ that has ended
                    // its turn this round, below), as ours has it on that turn, instead of none
                    let theirOffers = (tj["theirOffers"] as? [[String: Any]]) ?? [], ourOffers = (tj["ourOffers"] as? [[String: Any]]) ?? []
                    let theirsDuration = theirOffers.first(where: isPeaceTreaty).map { ($0["duration"] as? Int) ?? 0 }
                    let theirsRun = (theirsDuration ?? 0) > 0
                    for oj in ourOffers where isPeaceTreaty(oj) {
                        let duration = (oj["duration"] as? Int) ?? 0
                        if duration > 0 {
                            state.civs[mi].peaceTreatyUntil[otherId] = state.turn + duration
                            // theirOffers equal to ourOffers: the copy has not had its first end of turn yet
                            if let t = theirsDuration { state.civs[mi].peaceTreatyStartDuration[otherId] = t }
                        } else if theirsRun { lastTurnOfTreaty = true }
                        // remakePeaceTreaty(0): a Peace Treaty trade of its own with both offers at 0, which this civ's next
                        // nextTurnTrades drops with "[Peace Treaty] from [..] has ended"
                        else if theirsDuration == 0 && (ourOffers + theirOffers).allSatisfy(isPeaceTreaty) { remadeAtZero = true }
                    }
                }
                if lastTurnOfTreaty && state.civs[mi].peaceTreatyUntil[otherId] == nil { state.civs[mi].peaceTreatyUntil[otherId] = state.turn }
                if remadeAtZero && state.civs[mi].peaceTreatyUntil[otherId] == nil {
                    state.civs[mi].peaceTreatyUntil[otherId] = state.turn; state.civs[mi].peaceTreatyStartDuration[otherId] = 0
                }
                importedTrades.append((myId, otherId, trades))
            }
            if let flags = cj["flagsCountdown"] as? [String: Any] { for (k, v) in flags { if let n = (v as? NSNumber)?.intValue { state.civs[mi].civFlags[k] = n } } }   // Unciv Civilization.flagsCountdown
            // Unciv Civilization.disabledCityConstructions ("Disable in all cities"): what a city founded or conquered later
            // takes in City.resetDisabledConstructions (CityFounder.kt:90, CityConquestFunctions.kt:371) - ours left it
            // out, so a human's new city built what the player had disabled everywhere
            if let dis = cj["disabledCityConstructions"] as? [String] { state.civs[mi].disabledCivConstructions = Set(dis) }
            if let qm = cj["questManager"] as? [String: Any], state.civs[mi].isCityState {
                state.civs[mi].globalQuestCountdown = (qm["globalQuestCountdown"] as? Int) ?? -1
                for (k, v) in (qm["unitsToKillForCiv"] as? [String: Any]) ?? [:] { if let id = civIdByKey[k], let n = (v as? NSNumber)?.intValue { state.civs[mi].unitsToKillForCiv[id] = n } }
                for (k, v) in (qm["unitsKilledFromCiv"] as? [String: Any]) ?? [:] {
                    guard let attacker = civIdByKey[k], let inner = v as? [String: Any] else { continue }
                    for (hk, hv) in inner { if let helper = civIdByKey[hk], let n = (hv as? NSNumber)?.intValue { state.civs[mi].unitsKilledFromCiv[attacker, default: [:]][helper] = n } }
                }
                for (k, v) in (qm["individualQuestCountdown"] as? [String: Any]) ?? [:] { if let id = civIdByKey[k], let n = (v as? NSNumber)?.intValue { state.civs[mi].individualQuestCountdown[id] = n } }
                for qj in (qm["assignedQuests"] as? [[String: Any]]) ?? [] {
                    guard let qname = qj["questName"] as? String, let qdef = rs.quests.first(where: { $0.name == qname }) else { continue }
                    let assignee = (qj["assignee"] as? String).flatMap { civIdByKey[$0] }
                    let start = (qj["assignedOnTurn"] as? Int).map { $0 + 1 } ?? state.turn   // Unciv assignedOnTurn is zero-based
                    var target = (qj["data1"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    // These quests keep a civID in data1 (getCityStateTarget / getCivilizationToFindForQuest /
                    // getMostRecentBully); ours keeps the civ's id. Left as "Budapest", isObsolete read it as a
                    // defeated civ and dropped the quest on the first turn (t_45: Ragusa's Conquer City State, so a
                    // third quest - a Great Merchant - was handed out where Unciv's two slots were still full).
                    if GameState.civTargetQuests.contains(qname), let t = target { target = civIdByKey[t].map { String($0) } ?? t }
                    // Unciv ClearBarbarianCamp.getAssignedQuestData: the camp's position as data1 = x, data2 = y (QuestManager.
                    // barbarianCampCleared compares `data1.toInt() == location.x && data2.toInt() == location.y`); ours keeps the
                    // tile as "q,r" - read as data1 alone, the quest was obsolete on its first check (isQuestObsolete)
                    // Unciv SpreadReligion: data1 is the religion's display name, data2 its name - the one completion checks
                    if qname == "Spread Religion", let d2 = qj["data2"] as? String, !d2.isEmpty { target = d2 }
                    if qname == "Clear Barbarian Camp", let x = target.flatMap({ Int($0) }), let y = (qj["data2"] as? String).flatMap({ Int($0) }) {
                        let o = frame.ours(x: x, y: y); let c = HexCoord.fromOffset(col: o.col, row: o.row); target = "\(c.q),\(c.r)"
                    }
                    state.civs[mi].quests.append(Quest(id: state.newId(), name: qname, cityStateId: myId, assigneeId: assignee, target: target, startTurn: start, endTurn: qdef.duration > 0 ? start + Int(state.speed.modifier * Double(qdef.duration)) : 0))
                }
            }
        }

        // Unciv keeps each trade twice - `currentTrade` in the acceptor's DiplomacyManager and `reverse()` in the other's -
        // and each side counts ITS copy down in its own turn. Pair the copies (same offers, reversed, in the order the
        // trades were added) and turn every timed offer into one deal carrying both durations; a trade one side has
        // already dropped keeps only the other side's copy. Ours read each side's copy on its own and let the last
        // one win, or added gold per turn twice.
        do {
            struct ImpOffer { let type: String; let name: String; let amount: Int; let duration: Int }
            typealias ImpTrade = (ours: [ImpOffer], theirs: [ImpOffer])
            func offers(_ list: Any?) -> [ImpOffer] {
                ((list as? [[String: Any]]) ?? []).map { ImpOffer(type: ($0["type"] as? String) ?? "", name: ($0["name"] as? String) ?? "", amount: ($0["amount"] as? Int) ?? 1, duration: ($0["duration"] as? Int) ?? -1) }
            }
            func kindOf(_ o: ImpOffer) -> Deal.Kind? {
                switch o.type {
                case "Luxury_Resource", "Strategic_Resource": return rs.resources[o.name]?.isStockpiled == true ? nil : .resource
                case "Gold_Per_Turn": return .goldPerTurn
                case "Agreement" where o.name == "Open Borders": return .openBorders
                case "Treaty" where o.name == "Research Agreement": return .researchAgreement
                case "Treaty" where o.name == "Defensive Pact": return .defensivePact
                default: return nil
                }
            }
            func sameOffers(_ x: [ImpOffer], _ y: [ImpOffer]) -> Bool {
                guard x.count == y.count else { return false }
                var rest = y
                for o in x {
                    guard let k = rest.firstIndex(where: { $0.type == o.type && $0.name == o.name && $0.amount == o.amount }) else { return false }
                    rest.remove(at: k)
                }
                return true
            }
            var done: Set<[Int]> = []
            for entry in importedTrades {
                let a = entry.me, b = entry.other
                guard !done.contains([min(a, b), max(a, b)]) else { continue }
                done.insert([min(a, b), max(a, b)])
                let listA: [ImpTrade] = entry.trades.map { (offers($0["ourOffers"]), offers($0["theirOffers"])) }
                let listB: [ImpTrade] = (importedTrades.first { $0.me == b && $0.other == a }?.trades ?? []).map { (offers($0["ourOffers"]), offers($0["theirOffers"])) }
                /// One trade: `tA` is a's copy, `tB` b's copy (either may be missing).
                func makeDeals(_ tA: ImpTrade?, _ tB: ImpTrade?, _ iA: Int, _ iB: Int) {
                    let tradeId = state.newId()
                    // EVLOG: each side's copy as Unciv's EvLog.tradeSummary prints it when that side drops it
                    if EvLog.on {
                        for (civ, other, copy, index) in [(a, b, tA, iA), (b, a, tB, iB)] {
                            guard let t = copy else { continue }
                            let all = t.ours + t.theirs
                            let kind = all.contains { kindOf($0) != nil && $0.duration >= 0 } ? 0 : all.contains { $0.name == "Peace Treaty" } ? 1 : 2
                            EvLog.importedTrades.append((civ, other, index, tradeId, GameState.evJoin(all.map(\.name)), kind))
                        }
                    }
                    // The whole trade, which nextTurnTrades reads for a peace treaty bought with gold per turn: its Peace
                    // Treaty runs out silently while the gold goes on and is announced with it (TradeLogic.nextTurnTrades)
                    func offerJSON(_ list: [ImpOffer]) -> [[String: Any]] { list.map { ["type": $0.type, "name": $0.name, "amount": $0.amount, "duration": $0.duration] } }
                    importedRecords.append((tradeId, a, b, offerJSON(tA?.ours ?? tB?.theirs ?? []), offerJSON(tA?.theirs ?? tB?.ours ?? []), tA == nil, tB == nil))
                    // Deal.tradeContent: the whole trade (immediate offers too), civ offers named by our nation as ours
                    // are (GameState.tradeContent), a city by its Unciv id - what Trade.equalTrade compares
                    var content: [TradeOfferContent] = []
                    for (giver, list) in [(a, tA?.ours ?? tB?.theirs ?? []), (b, tA?.theirs ?? tB?.ours ?? [])] {
                        for o in list {
                            var name = o.name
                            if ["Introduction", "WarDeclaration", "PeaceProposal"].contains(o.type), let id = civIdByKey[o.name],
                               let nation = state.civs.first(where: { $0.id == id })?.nation { name = nation }
                            content.append(TradeOfferContent(giver: giver, type: o.type, name: name, amount: o.amount))
                        }
                    }
                    // (giver, receiver, a's copy of the giver's offers, b's copy of them)
                    for (giver, receiver, aList, bList) in [(a, b, tA?.ours, tB?.theirs), (b, a, tA?.theirs, tB?.ours)] {
                        var bRest = bList ?? []
                        for o in aList ?? bList ?? [] {
                            guard let kind = kindOf(o), o.duration >= 0 else { continue }
                            var aDur: Int? = nil, bDur: Int? = nil
                            if aList != nil {
                                aDur = o.duration
                                if let k = bRest.firstIndex(where: { $0.type == o.type && $0.name == o.name && $0.amount == o.amount }) { bDur = bRest[k].duration; bRest.remove(at: k) }
                            } else { bDur = o.duration }
                            let giverDur = giver == a ? aDur : bDur, receiverDur = giver == a ? bDur : aDur
                            var deal = Deal(id: state.newId(), kind: kind, from: giver, to: receiver, resource: kind == .resource ? o.name : nil, turnsLeft: max(giverDur ?? 0, receiverDur ?? 0))
                            deal.amount = kind == .openBorders ? 0 : o.amount
                            deal.tradeId = tradeId
                            deal.tradeContent = content
                            if let g = giverDur { deal.fromLeft = g } else { deal.fromLeft = 0; deal.fromGone = true }
                            if let r = receiverDur { deal.toLeft = r } else { deal.toLeft = 0; deal.toGone = true }
                            state.deals.append(deal)
                        }
                    }
                }
                var usedB = Array(repeating: false, count: listB.count)
                var nextB = 0
                for (iA, tA) in listA.enumerated() {
                    var match: Int? = nil
                    for k in nextB..<max(nextB, listB.count) where !usedB[k] && sameOffers(listB[k].ours, tA.theirs) && sameOffers(listB[k].theirs, tA.ours) { match = k; break }
                    if let m = match { usedB[m] = true; nextB = m + 1; makeDeals(tA, listB[m], iA, m) } else { makeDeals(tA, nil, iA, -1) }
                }
                for (k, tB) in listB.enumerated() where !usedB[k] { makeDeals(nil, tB, -1, k) }
            }
            state.deals.removeAll { $0.fromGone && $0.toGone }
        }
        // Unciv keeps a demand and a Declaration of Friendship waiting for their receiver as popupAlerts, answered in
        // NextTurnAutomation.respondToPopupAlerts; ours answers `pendingDemands` / `pendingOffers`, so the ones in the
        // save become those, in the alerts' order (a demand refused on the first turn was simply never made). A human
        // is offered friendship by the alert alone, as in our game (DiplomacyAutomation.offerDeclarationOfFriendship,
        // GameController.declareFriendship): its popup answers it, and an automated turn answers it from popupAlerts.
        for cj in civsJSON {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            guard let toId = civIdByKey[key] else { continue }
            for a in (cj["popupAlerts"] as? [[String: Any]]) ?? [] {
                guard let t = (a["type"] as? String).flatMap({ AlertType(rawValue: $0) }), let fromId = ((a["value"] as? String).flatMap { civIdByKey[$0] }) else { continue }
                if let demand = Demand.allCases.first(where: { $0.demandAlert == t }) {
                    state.pendingDemands.append(DemandRequest(id: state.newId(), from: fromId, to: toId, demand: demand))
                } else if t == .DeclarationOfFriendship && state.civ(toId)?.isPlayer != true {
                    var offer = TradeOffer(id: state.newId(), from: fromId, to: toId, turnCreated: state.turn)
                    offer.give.friendship = true; offer.want.friendship = true
                    state.pendingOffers.append(offer)
                }
            }
        }
        // Unciv GameInfo.setTransients: every DiplomacyManager's updateHasOpenBorders
        state.updateAllHasOpenBorders()

        // Tiles
        var presentIndices: Set<Int> = []
        var order: [Int] = []
        for (i, t) in tileList.enumerated() {
            let (x, y) = ucoords[i]
            let o = frame.ours(x: x, y: y)
            let c = HexCoord.fromOffset(col: o.col, row: o.row)
            guard let idx = map.index(of: c) else { continue }
            presentIndices.insert(idx)
            order.append(idx)
            var tile = map.tiles[idx]
            tile.baseTerrain = (t["baseTerrain"] as? String) ?? "Ocean"
            tile.features = ((t["terrainFeatures"] as? [String]) ?? []).filter { rs.terrains[$0] != nil }
            tile.naturalWonder = t["naturalWonder"] as? String
            tile.resource = (t["resource"] as? String).flatMap { rs.resources[$0] != nil ? $0 : nil }
            tile.resourceAmount = (t["resourceAmount"] as? Int) ?? 0
            tile.continent = (t["continent"] as? Int) ?? -1   // Unciv Tile.continent (Kotlin default -1, omitted by the writer)
            tile.improvement = (t["improvement"] as? String).flatMap { rs.improvements[$0] != nil || $0 == Names.barbarianCamp || $0 == Names.ancientRuins ? $0 : nil }
            tile.pillaged = (t["improvementIsPillaged"] as? Bool) ?? false
            tile.roadPillaged = (t["roadIsPillaged"] as? Bool) ?? false
            let road = (t["roadStatus"] as? String) ?? "None"
            tile.roads = road != "None"; tile.railroad = road == "Railroad"
            if let qs = t["improvementQueue"] as? [[String: Any]] {   // Unciv Tile.improvementQueue: the work in progress, then the queued improvement
                if let q = qs.first, let imp = q["improvement"] as? String { tile.improvementInProgress = imp; tile.improvementTurnsLeft = (q["turnsToImprovement"] as? Int) ?? 0 }
                if qs.count > 1, let imp = qs[1]["improvement"] as? String { tile.queuedImprovement = imp; tile.queuedImprovementTurns = (qs[1]["turnsToImprovement"] as? Int) ?? 0 }
            }
            tile.roadOwner = (t["roadOwner"] as? String).flatMap { $0.isEmpty ? nil : civIdByKey[$0] }
            if let explored = t["exploredBy"] as? [String] { for k in explored { if let id = civIdByKey[k], let ci = state.civIndex(id) { state.civs[ci].explored.insert(c) } } }
            // Unciv TileHistory: {"turn": [owningCivName, "N"/"R"/"C"]}
            if let hist = t["history"] as? [String: Any] {
                for (k, v) in hist { if let turnKey = Int(k).map({ $0 + 1 }), let arr = v as? [Any] {   // Unciv keys by gameInfo.turns (zero-based)
                    let owner = (arr.first as? String).flatMap { $0.isEmpty ? nil : civIdByKey[$0] }; tile.history[turnKey] = TileHistoryEntry(owner: owner, center: arr.count > 1 ? (arr[1] as? String ?? "N") : "N") } }
            }
            map.tiles[idx] = tile
        }
        // Unciv's tileMap has no entry outside a hexagonal map's radius. Ours is a rectangle, so the cells the save
        // never mentions are not tiles at all - without this they stayed as Ocean and answered `contains` with yes,
        // and a settler counted them when scoring where to explore.
        map.missing = Set(map.tiles.indices).subtracting(presentIndices)
        // Unciv keeps the tiles in the order the file lists them and iterates `tileMap.values` in that order.
        // Ours are a rectangle in row-major order, which is a different sequence entirely.
        map.uncivOrder = order
        map.buildNeighborTable()   // `missing` just changed what `contains` answers
        // Rivers: with the mirrored frame Unciv bottom / bottom-left / bottom-right are our S / SW / SE edges.
        for (i, t) in tileList.enumerated() {
            let (x, y) = ucoords[i]; let o = frame.ours(x: x, y: y); let c = HexCoord.fromOffset(col: o.col, row: o.row)
            if (t["hasBottomRiver"] as? Bool) == true { map.setRiver(c, dir: HexCoord.dirS) }
            if (t["hasBottomLeftRiver"] as? Bool) == true { map.setRiver(c, dir: HexCoord.dirSW) }
            if (t["hasBottomRightRiver"] as? Bool) == true { map.setRiver(c, dir: HexCoord.dirSE) }
        }
        for i in map.tiles.indices { let c = map.tiles[i].coord; map.tiles[i].riverAdjacent = (0..<6).contains { d in map.hasRiver(between: c, c.neighbor(d)) } }
        state.map = map
        state.map.resetCoastAdjacency()   // Unciv loads fresh Tile objects: no lazy has been read yet

        // Cities
        var cityIdByKey: [String: Int] = [:]
        var pendingFreeBuildings: [String: [String]] = [:]   // Unciv keys these by the receiving city's id
        for (civIndexInSave, cj) in civsJSON.enumerated() {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            guard let civId = civIdByKey[key] else { continue }
            for (cityIndexInSave, city) in ((cj["cities"] as? [[String: Any]]) ?? []).enumerated() {
                let (x, y) = pos(city["location"]); let o = frame.ours(x: x, y: y)
                let coord = HexCoord.fromOffset(col: o.col, row: o.row)
                guard state.map.contains(coord) else { continue }
                var c = City(id: state.newId(), civId: civId, name: (city["name"] as? String) ?? "City", coord: coord)
                if let k = city["id"] as? String { cityIdByKey[k] = c.id; c.uncivId = k }   // Unciv City.id: the hash input for every city-scoped roll
                if let pop = city["population"] as? [String: Any] {
                    c.population = max(1, (pop["population"] as? Int) ?? 1)
                    c.foodStored = Double((pop["foodStored"] as? NSNumber)?.doubleValue ?? 0)
                    if let spec = pop["specialistAllocations"] as? [String: Any] {
                        // one key at a time, in the file's order - the Counter order (see specialistKeyOrders)
                        let fileOrder = importSpecialistOrders["\(civIndexInSave):\(cityIndexInSave)"] ?? []
                        c.specialists = [:]
                        for k in fileOrder + spec.keys.filter({ !fileOrder.contains($0) }).sorted() {
                            if let v = spec[k] { c.specialists[k] = (v as? NSNumber)?.intValue ?? 0 }
                        }
                    }
                }
                if let cc = city["cityConstructions"] as? [String: Any] {
                    c.buildings = ((cc["builtBuildings"] as? [String]) ?? []).filter { rs.buildings[$0] != nil }
                    // Unciv CityConstructions.freeBuildingsProvidedFromThisCity: keyed by the city that receives
                    // the building. A free building pays no maintenance, and dropping it charged for it.
                    if let provided = cc["freeBuildingsProvidedFromThisCity"] as? [String: Any] {
                        for (receiverKey, v) in provided {
                            let names: [String] = ((v as? [Any]) ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["value"] as? String) }
                            pendingFreeBuildings[receiverKey, default: []] += names.filter { rs.buildings[$0] != nil }
                        }
                    }
                    let queue = (cc["constructionQueue"] as? [String]) ?? []
                    func production(_ n: String) -> Production? { if rs.units[n] != nil { return .unit(n) }; if rs.buildings[n] != nil { return .building(n) }; return nil }
                    if let first = queue.first {
                        if let p = production(first) { c.currentProduction = p } else if City.perpetualConstructions.contains(first) { c.convertProductionTo = first }   // Unciv PerpetualConstruction; "Nothing" is Idle
                    }
                    c.productionQueue = queue.dropFirst().compactMap(production)
                    // a perpetual behind real entries is the queue's trailing one (Unciv addToQueue keeps it last)
                    if c.currentProduction != nil, let last = queue.last, City.perpetualConstructions.contains(last) { c.convertProductionTo = last }
                    if let prog = cc["inProgressConstructions"] as? [String: Any] {
                        for (k, v) in prog { if let n = v as? NSNumber, n.intValue > 0 { c.inProgressConstructions[k] = n.intValue } }
                        if let cur = c.currentProduction, let v = c.inProgressConstructions.removeValue(forKey: cur.name) { c.productionStored = Double(v); c.workDoneOn = cur.name }
                    }
                    if let o = cc["productionOverflow"] as? NSNumber { c.productionOverflow = o.intValue }
                    if let userSet = cc["currentConstructionIsUserSet"] as? Bool { c.currentConstructionIsUserSet = userSet }   // Unciv CityConstructions.currentConstructionIsUserSet
                }
                if let exp = city["expansion"] as? [String: Any], let v = exp["cultureStored"] as? NSNumber { c.expansionCulture = v.doubleValue }
                c.health = (city["health"] as? Int) ?? 200
                c.isPuppet = (city["isPuppet"] as? Bool) ?? false
                c.connectedToCapital = (city["connectedToCapitalStatus"] as? Bool) ?? false   // Unciv City.connectedToCapitalStatus
                c.razing = (city["isBeingRazed"] as? Bool) ?? false
                c.acquiredTurn = (city["turnAcquired"] as? Int) ?? 0
                c.demandedResource = (city["demandedResource"] as? String) ?? ""
                c.isOriginalCapital = (city["isOriginalCapital"] as? Bool) ?? false
                c.avoidGrowth = (city["avoidGrowth"] as? Bool) ?? false
                c.manualSpecialists = (city["manualSpecialists"] as? Bool) ?? false
                c.disabledConstructions = Set((city["disabledConstructions"] as? [String]) ?? (city["manualBuildingsDisabled"] as? [String]) ?? [])   // Unciv City.disabledConstructions
                c.shouldReassignPopulation = (city["shouldReassignPopulation"] as? Bool) ?? false
                if let focus = city["cityAIFocus"] as? String { c.cityFocus = focus }
                c.hasSoldBuildingThisTurn = (city["hasSoldBuildingThisTurn"] as? Bool) ?? false
                c.attackedThisTurn = (city["attackedThisTurn"] as? Bool) ?? false   // Unciv City.attackedThisTurn
                for (k, v) in (city["unitToPromotions"] as? [String: Any]) ?? [:] { if let pj = v as? [String: Any] { c.defaultPromotions[k] = SavedUnitPromotions(promotions: ((pj["promotions"] as? [String]) ?? []).filter { rs.promotions[$0] != nil }, xp: (pj["XP"] as? Int) ?? 0, numberOfPromotions: (pj["numberOfPromotions"] as? Int) ?? 0) } }   // Unciv City.unitToPromotions: a UnitPromotions (XP, promotions, numberOfPromotions; json leaves zeros out)
                for (k, v) in (city["unitShouldUseSavedPromotion"] as? [String: Any]) ?? [:] { if (v as? Bool) == true { c.useDefaultPromotions.insert(k) } }
                // Unciv foundingCiv "" (a city-state won by Diplomatic Marriage - the json leaves the default out) or
                // a name no civ carries is no founder at all: -1, as marrying sets it; `civName == foundingCiv` fails.
                if let f = city["foundingCiv"] as? String, let id = civIdByKey[f] { c.originalOwner = id } else { c.originalOwner = -1 }
                // Unciv City.previousOwner (a civID, "" by default): CityConquestFunctions reads it for a city retaken in resistance
                c.previousOwner = (city["previousOwner"] as? String).flatMap { $0.isEmpty ? nil : civIdByKey[$0] } ?? -1
                if let flags = city["flagsCountdown"] as? [String: Any] {
                    c.resistanceTurns = (flags["Resistance"] as? NSNumber)?.intValue ?? 0
                    c.wltkdTurns = (flags["WeLoveTheKing"] as? NSNumber)?.intValue ?? 0
                    c.resourceDemandCooldown = (flags["ResourceDemand"] as? NSNumber)?.intValue ?? -1
                }
                if let rel = city["religion"] as? [String: Any] {
                    c.religionsAtSomePointAdopted = Set((rel["religionsAtSomePointAdopted"] as? [String]) ?? [])
                    // Unciv CityReligionManager.isBlockedHolyCity: ours keeps a blocked holy city as holyCityOf set, isHolyCity false
                    if let holy = rel["religionThisIsTheHolyCityOf"] as? String { c.holyCityOf = holy; c.isHolyCity = !((rel["isBlockedHolyCity"] as? Bool) ?? false) }
                    if let pressures = rel["pressures"] as? [String: Any] {
                        // one key at a time, in the file's order - the Counter order (see pressureKeyOrders)
                        let fileOrder = importPressureOrders["\(civIndexInSave):\(cityIndexInSave)"] ?? []
                        c.religionPressure = [:]
                        for k in fileOrder + pressures.keys.filter({ !fileOrder.contains($0) }).sorted() {
                            if let v = pressures[k] { c.religionPressure[k] = (v as? NSNumber)?.doubleValue ?? 0 }
                        }
                    }
                }
                // Unciv CityReligionManager's constructor runs clearAllPressures (`pressures.add(noReligionName, 100)`), and
                // libGDX writes a field only when it differs from a new instance's: a city still at {noReligionName: 100} -
                // one citizen, no religion ever pressed on it - has no `pressures` in the save (no `religion` at all when
                // nothing else differs either), and Unciv reads it back as that default (a test game, Brussels: the a state comparison
                // had Unciv's 100 and our nothing)
                if (city["religion"] as? [String: Any])?["pressures"] == nil { c.religionPressure = [noReligionName: 100] }
                for tp in (city["tiles"] as? [[String: Any]]) ?? [] {
                    let (tx, ty) = pos(tp); let to = frame.ours(x: tx, y: ty); let tc = HexCoord.fromOffset(col: to.col, row: to.row)
                    // The save's array is the order Unciv's own HashSet walked when it was written.
                    if state.map.contains(tc) { c.addTile(tc); state.map[tc]?.ownerCivId = civId }
                }
                c.addTile(coord); state.map[coord]?.ownerCivId = civId; state.map[coord]?.cityId = c.id
                for tp in (city["workedTiles"] as? [[String: Any]]) ?? [] {
                    let (tx, ty) = pos(tp); let to = frame.ours(x: tx, y: ty); let tc = HexCoord.fromOffset(col: to.col, row: to.row)
                    // Unciv: a city may work a tile owned by another of our cities, so do not require ownership.
                    c.workedTiles.append(tc); state.map[tc]?.workingCityId = c.id
                }
                for tp in (city["lockedTiles"] as? [[String: Any]]) ?? [] {
                    let (tx, ty) = pos(tp); let to = frame.ours(x: tx, y: ty); c.lockedTiles.insert(HexCoord.fromOffset(col: to.col, row: to.row))
                }
                if c.isCapital, let ci = state.civIndex(civId) { state.civs[ci].capitalCityId = c.id }
                state.cities.append(c)
                // The save writes each civ's cities in ITS list order, so reading them back in file order
                // rebuilds `Civilization.cities` exactly.
                if let ci = state.civIndex(civId) { state.civs[ci].cityIds.append(c.id) }
            }
        }
        // Unciv keeps no working city on a tile: Tile.getWorkingCity() is `owningCity` if it works the tile, else the first
        // other city of the tile's OWNER that does (Tile.kt:460-464), and nothing on an unowned tile. A save may list one
        // tile in two cities' workedTiles - a city traded away (TradeLogic, City.moveToCiv) keeps its tiles that another
        // city of the old owner worked in that city's list until its unassignExtraPopulation - and the last city read
        // here took the tile, so the traded city lost three of its worked tiles at its first end of turn.
        var owningCity: [HexCoord: Int] = [:]
        for c in state.cities { for t in c.tiles { owningCity[t] = c.id } }
        for c in state.cities { for t in c.workedTiles { state.map[t]?.workingCityId = nil } }
        for (t, oc) in owningCity {
            guard let owner = state.city(oc), let ci = state.civIndex(owner.civId) else { continue }
            if owner.workedTiles.contains(t) { state.map[t]?.workingCityId = oc; continue }
            state.map[t]?.workingCityId = state.civs[ci].cityIds.first { $0 != oc && state.city($0)?.workedTiles.contains(t) == true }
        }
        // The free buildings are keyed by the receiving city, which may be read before that city exists.
        for (receiverKey, names) in pendingFreeBuildings {
            guard let cityId = cityIdByKey[receiverKey], let idx = state.cities.firstIndex(where: { $0.id == cityId }) else { continue }
            for n in names where !state.cities[idx].freeBuildingsProvidedFromThisCity.contains(n) { state.cities[idx].freeBuildingsProvidedFromThisCity.append(n) }
        }
        // Unciv CivConstructions.freeBuildings / freeStatBuildingsProvided / freeSpecificBuildingsProvided, all keyed by
        // city id. The first stays on the civ - never cleared, and read through the city's CURRENT owner
        // (freeBuildingNames), so a city another civ holds does not see it; the other two remember which cities have
        // been served, so a Legalism or Tradition city is not handed a second building after the load.
        for cj in civsJSON {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            guard let civId = civIdByKey[key], let cv = state.civIndex(civId), let cc = cj["civConstructions"] as? [String: Any] else { continue }
            func names(_ v: Any) -> [String] { ((v as? [Any]) ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["value"] as? String) } }
            for (cityKey, v) in (cc["freeBuildings"] as? [String: Any]) ?? [:] {
                guard let cityId = cityIdByKey[cityKey] else { continue }
                let list = names(v).filter { rs.buildings[$0] != nil }
                state.civs[cv].freeBuildingsOfCities[cityId] = list
            }
            for (stat, v) in (cc["freeStatBuildingsProvided"] as? [String: Any]) ?? [:] { state.civs[cv].freeStatBuildingsProvided[stat] = names(v).compactMap { cityIdByKey[$0] } }
            for (b, v) in (cc["freeSpecificBuildingsProvided"] as? [String: Any]) ?? [:] { state.civs[cv].freeSpecificBuildingsProvided[b] = names(v).compactMap { cityIdByKey[$0] } }
        }
        // Unciv Civilization.proximity is saved with the game and only recomputed when a city is founded, destroyed
        // or changes hands.
        for cj in civsJSON {
            let key = (cj["civID"] as? String) ?? (cj["civName"] as? String) ?? ""
            guard let civId = civIdByKey[key], let cv = state.civIndex(civId), let prox = cj["proximity"] as? [String: Any] else { continue }
            let levels: [String: Proximity] = ["None": .none, "Neighbors": .neighbors, "Close": .close, "Far": .far, "Distant": .distant]
            for (other, v) in prox { if let oid = civIdByKey[other], let level = (v as? String).flatMap({ levels[$0] }) { state.civs[cv].proximityTo[oid] = level.rawValue } }
        }
        for ci in state.civs.indices { for si in state.civs[ci].spies.indices { if let c = pendingSpyCoords[state.civs[ci].spies[si].id] { state.civs[ci].spies[si].cityId = state.city(at: c)?.id } } }
        for ci in state.civs.indices where state.civs[ci].holyCityId == nil { if let rn = state.civs[ci].religionName, let hc = state.cities.first(where: { $0.holyCityOf == rn }) { state.civs[ci].holyCityId = hc.id } }

        // Units live on tiles in Unciv saves.
        var unitIdByUncivId: [Int: Int] = [:]   // MapUnit.id → ours, for an Event alert's `unitId=`
        for (i, t) in tileList.enumerated() {
            let (x, y) = ucoords[i]; let o = frame.ours(x: x, y: y); let coord = HexCoord.fromOffset(col: o.col, row: o.row)
            var unitJSONs: [[String: Any]] = []
            if let u = t["militaryUnit"] as? [String: Any] { unitJSONs.append(u) }
            if let u = t["civilianUnit"] as? [String: Any] { unitJSONs.append(u) }
            unitJSONs += (t["airUnits"] as? [[String: Any]]) ?? []
            for uj in unitJSONs {
                guard let name = uj["name"] as? String, rs.units[name] != nil, let owner = uj["owner"] as? String, let civId = civIdByKey[owner] else { continue }
                var u = Unit(id: state.newId(), civId: civId, name: name, coord: coord, movementLeft: Double((uj["currentMovement"] as? NSNumber)?.doubleValue ?? 0))
                u.health = (uj["health"] as? Int) ?? 100
                u.originalCiv = (uj["originalOwner"] as? String).flatMap { civIdByKey[$0] } ?? civId
                // Unciv writes no "promotions" object for a unit that has none: zero promotions taken. Left nil, the
                // legacy count ran and a unit upgraded into free promotions (Formation I) was valued as promoted.
                u.numberOfPromotions = 0
                if let promo = uj["promotions"] as? [String: Any] {
                    u.promotions = ((promo["promotions"] as? [String]) ?? []).filter { rs.promotions[$0] != nil }
                    u.xp = (promo["XP"] as? Int) ?? 0; u.spentPromotionXP = 0; u.numberOfPromotions = (promo["numberOfPromotions"] as? Int) ?? 0   // Unciv stores the XP still available
                }
                u.turnsFortified = (uj["turnsFortified"] as? Int) ?? 0
                if let sm = uj["statusMap"] as? [String: Any] { for (k, v) in sm { if let d = v as? [String: Any], rs.promotions[k] != nil { u.statuses[k] = (d["turnsLeft"] as? Int) ?? 1 } } }
                u.attacksThisTurn = (uj["attacksThisTurn"] as? Int) ?? 0
                u.due = (uj["due"] as? Bool) ?? true
                // Unciv MapUnit.movementMemories / mostRecentMoveType (movement arrows)
                if let mm = uj["movementMemories"] as? [[String: Any]] {
                    u.movementMemories = mm.map { m in let (mx, my) = pos(m["position"]); let mo = frame.ours(x: mx, y: my); return MovementMemory(coord: HexCoord.fromOffset(col: mo.col, row: mo.row), type: (m["type"] as? String) ?? "UnitMoved") }
                }
                u.mostRecentMoveType = (uj["mostRecentMoveType"] as? String) ?? "UnitMoved"
                // Unciv MapUnit.attacksSinceTurnStart (attack arrows)
                if let atk = uj["attacksSinceTurnStart"] as? [Any] {
                    u.attacksSinceTurnStart = atk.map { a in let (ax, ay) = pos(a); let ao = frame.ours(x: ax, y: ay); return HexCoord.fromOffset(col: ao.col, row: ao.row) }
                }
                u.religion = uj["religion"] as? String
                u.isTransported = (uj["isTransported"] as? Bool) ?? false
                u.religiousStrengthLost = (uj["religiousStrengthLost"] as? Int) ?? 0
                if let n = uj["instanceName"] as? String, !n.isEmpty { u.customName = n }
                if let dj = uj["automatedRoadConnectionDestination"] as? [String: Any] { let (dx, dy) = pos(dj); let dmo = frame.ours(x: dx, y: dy); u.order = .connectRoad(HexCoord.fromOffset(col: dmo.col, row: dmo.row)) }   // Unciv MapUnit.automatedRoadConnectionDestination
                let action = (uj["action"] as? String) ?? ""
                // Unciv MapUnit.setTransients: a legacy action "Automate" becomes `automated = true`
                let automated = ((uj["automated"] as? Bool) ?? false) || action == "Automate"
                if action.hasPrefix("Fortify") { u.order = action.contains("until healed") ? .fortifyUntilHealed : .fortify }
                else if action.hasPrefix("Sleep") { u.order = action.contains("until healed") ? .sleepUntilHealed : .sleep }
                else if action.lowercased().hasPrefix("explore") { u.order = .explore }
                else if action == "Set up" || action == "Set Up" { u.isSetUp = true }   // Unciv UnitActionType.SetUp "Set up" (ours once wrote "Set Up")
                else if action == "Guard" { u.order = .guardPost }
                if let esc = uj["escorting"] as? Bool { u.escorting = esc }
                if action.hasPrefix("moveTo") {
                    let nums = action.dropFirst(6).split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Int($0) }
                    if nums.count == 2 { let mo = frame.ours(x: nums[0], y: nums[1]); u.order = .moveTo(HexCoord.fromOffset(col: mo.col, row: mo.row)) }
                }
                // Unciv MapUnit.doAction: `if (isAutomated()) UnitAutomation.automateUnitMoves(this)` for every kind of
                // unit - a military unit, a Work Boat or a great person automates too, it does not explore
                u.automated = automated   // its own field beside the action: an automated unit may be fortified, asleep or moving
                if let charges = uj["abilityToTimesUsed"] as? [String: Any], let def = rs.units[name] {
                    u.abilityToTimesUsed = charges.compactMapValues { ($0 as? NSNumber)?.intValue }
                    let used = u.abilityToTimesUsed["Can Spread Religion"] ?? charges.values.compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
                    let total = def.spreadCharges > 0 ? def.spreadCharges : (def.uniqueObjects.first { $0.pattern == "Can [] [] times" }?.int(1) ?? 0)
                    if total > 0 { u.charges = max(0, total - used) }
                }
                if let uid = (uj["id"] as? NSNumber)?.intValue { unitIdByUncivId[uid] = u.id }
                state.units.append(u)
            }
        }
        // The popup alerts were read with Unciv's values; ours name civilizations, cities and units by our ids
        for ci in state.civs.indices where !state.civs[ci].popupAlerts.isEmpty {
            let mapped = state.civs[ci].popupAlerts.map { a in
                PopupAlert(type: a.type, value: state.oursAlertValue(type: a.type, value: a.value, civIds: civIdByKey, cityIds: cityIdByKey, unitIds: unitIdByUncivId,
                                                                     tileAt: { x, y in let o = frame.ours(x: x, y: y); return HexCoord.fromOffset(col: o.col, row: o.row) }))
            }
            state.civs[ci].popupAlerts = mapped
        }

        // Barbarian encampments
        if let barb = root["barbarians"] as? [String: Any], let camps = barb["encampments"] as? [[String: Any]] {
            for camp in camps {
                let (x, y) = pos(camp["position"]); let o = frame.ours(x: x, y: y); let coord = HexCoord.fromOffset(col: o.col, row: o.row)
                guard state.map.contains(coord) else { continue }
                // Unciv BarbarianEncampment.destroyed: a destroyed camp stays listed until its 15-turn countdown runs
                // out, blocking new camps within 4 tiles and counting in the encampments hash that seeds placement
                var e = Encampment(position: coord); e.countdown = (camp["countdown"] as? Int) ?? 0; e.spawnedUnits = (camp["spawnedUnits"] as? Int) ?? -1
                e.destroyed = (camp["destroyed"] as? Bool) ?? false
                state.encampments.append(e)
            }
        }
        // Unciv GameStarter.addCivilizations adds the barbarians only `if (!newGameParameters.noBarbarians)`, and a load adds
        // nothing: a game without barbarians has no barbarian civilization at all, so none is made up here either
        if state.barbarianCivId == nil && s.barbarians { var b = Civilization(id: state.newId(), nation: "Barbarians", isPlayer: false); b.isBarbarian = true; state.civs.append(b) }
        // Unciv: barbarians are implicitly at war with everyone (no diplomacy entries).
        if let barb = state.barbarianCivId, let bi = state.civIndex(barb) {
            for i in state.civs.indices where !state.civs[i].isBarbarian && !state.civs[i].isSpectator { state.civs[i].atWarWith.insert(barb); state.civs[bi].atWarWith.insert(state.civs[i].id) }
        }

        // Current player / humans
        let humans = state.civs.filter { $0.isPlayer }
        if humans.isEmpty { var spec = Civilization(id: state.newId(), nation: "Spectator", isPlayer: true); spec.explored = Set(state.map.tiles.map { $0.coord }); spec.techs = Set(rs.techs.keys); state.civs.append(spec) }   // Unciv addCivTechs: a spectator has every tech
        if let cur = root["currentPlayer"] as? String, let curId = civIdByKey[cur], let idx = state.humans.firstIndex(where: { $0.id == curId }) { state.currentHumanIndex = idx }
        if let votes = root["diplomaticVictoryVotesCast"] as? [String: Any] {
            for (voter, chosen) in votes { guard let vid = civIdByKey[voter] else { continue }; state.diplomaticVictoryVotesCast[vid] = (chosen as? String).flatMap { civIdByKey[$0] } ?? -1 }
        }
        state.diplomaticVictoryVotesProcessed = (root["diplomaticVictoryVotesProcessed"] as? Bool) ?? false
        // Unciv GameInfo.historyStartTurn: 0-based like GameInfo.turns, -1 means a save from before replay existed
        if let h = root["historyStartTurn"] as? Int, h >= 0 { state.historyStartTurn = h + 1 }
        state.oneMoreTurnMode = (root["oneMoreTurnMode"] as? Bool) ?? false
        state.unitNamesTaken = Set((root["unitNamesTaken"] as? [String]) ?? [])   // Unciv GameInfo.unitNamesTaken
        // Unciv GameInfo.victoryData (winningCiv is the civ name)
        if let v = root["victoryData"] as? [String: Any], let w = (v["winningCiv"] as? String).flatMap({ civIdByKey[$0] }) {
            state.victoryData = VictoryRecord(winningCiv: w, victoryType: (v["victoryType"] as? String) ?? "", victoryTurn: (v["victoryTurn"] as? Int) ?? state.turn)
        }
        // Unciv DiplomacyManager.trades: every trade the save holds, the immediate offers too, one copy per side (a side
        // that already dropped its copy has none) - the records acceptTrade's recordTrade keeps for a trade made in play
        for p in importedRecords {
            let before = state.tradeRecords.count
            state.recordTrade(id: p.id, ours: p.a, theirs: p.b, ourSide: tradeSideFromJSON(p.aOffers, state: state), theirSide: tradeSideFromJSON(p.bOffers, state: state),
                              ourTail: offerListOrder(p.aOffers), theirTail: offerListOrder(p.bOffers))
            guard state.tradeRecords.count > before else { continue }
            if p.aGone { state.tradeRecords[before].setGone(for: p.a) }
            if p.bGone { state.tradeRecords[before].setGone(for: p.b) }
        }
        state.settings.humanPlayers = max(1, state.humans.count)
        state.settings.playerNation = state.humans.first?.nation ?? state.settings.playerNation
        state.settings.opponentCount = max(0, state.majorCivs.count - state.humans.count)
        // Unciv GameInfo.setTransients: `tileMap.setNeutralTransients()` once civInfo.setTransients has set the
        // owning cities, before updateCivilizationState - each civ's neutralRoads is rebuilt from Tile.roadOwner.
        state.setOwningCityTransients()   // civInfo.setTransients → CityExpansionManager.setTransients: setOwningCity per tile
        state.setNeutralTransients()
        state.invalidateHappiness()
        // Unciv GameInfo.setTransients ends with `updateOurTiles()` / `updateSightAndResources()` per civ,
        // which is where the stored supply gets its first value - inside updateCivilizationState's walk below, civ
        // by civ with the city-states first (the views too: this used to run updateExploration for every civ here).
        // Unciv's isDefeated() is computed (cities, or units for a civ that never held its capital); our isAlive is a
        // stored flag the save does not carry, so a civ destroyed before the save came back alive - still "at war" for
        // its old enemies (settled from turn 260: Japan counted its war with a dead Carthage and built units Unciv did not).
        state.refreshDefeatedFlags()
        // Unciv keeps no record of whose diplomacy managers already turned this round: each side's copy of a trade counts
        // its own ends of turn (DiplomacyTurnManager.nextTurnTrades), and the loaded game goes on from currentPlayer. Ours
        // is read from that position (after refreshDefeatedFlags: a defeated civ's endTurn stops before the managers) -
        // and a treaty read above as `turn + duration` is a round later for those civs: their copy next counts down at
        // their end of turn in the NEXT round, as addPeaceTreaty's `+ 1` has it for a treaty signed after that end.
        state.diplomacyTurnDoneThisRound = state.diplomacyTurnsDoneBeforeCurrentPlayer()
        for civId in state.diplomacyTurnDoneThisRound {
            guard let i = state.civIndex(civId) else { continue }
            for (other, until) in state.civs[i].peaceTreatyUntil { state.civs[i].peaceTreatyUntil[other] = until + 1 }
        }
        // Unciv GameInfo.updateCivilizationState walks the city-states first ("the happiness of major civ depends on
        // it") and, per civ, rebuilds the transient connection map (updateCitiesConnectedToCapital(initialSetup = true))
        // and then every city's happiness list and stats.
        state.updateCivilizationState()
        return state
    }


/// The reverse of `tradeSideJSON`: Unciv's offer list back into one side of an Epochs trade.
static func tradeSideFromJSON(_ offers: [[String: Any]], state: GameState) -> TradeSide {
    var side = TradeSide()
    for o in offers {
        let name = (o["name"] as? String) ?? ""
        let amount = (o["amount"] as? Int) ?? 1
        switch (o["type"] as? String) ?? "" {
        case "Gold": side.gold = amount
        case "Gold_Per_Turn": side.goldPerTurn = amount
        case "Strategic_Resource", "Luxury_Resource": side.resources += Array(repeating: name, count: max(1, amount))
        case "Stockpiled_Resource": side.stockpiles[name] = amount
        // Unciv TradeLogic: TradeOffer(city.id, TradeOfferType.City) - the name field carries the city id, not its display name
        case "City": if let c = state.cities.first(where: { !$0.uncivId.isEmpty && $0.uncivId == name }) ?? state.cities.first(where: { "\($0.id)" == name }) ?? state.cities.first(where: { $0.name == name }) { side.cities.append(c.id) }
        case "Introduction": if let c = state.civs.first(where: { $0.nation == name }) { side.introductions.append(c.id) }
        case "PeaceProposal": if let c = state.civs.first(where: { $0.nation == name }) { side.peaceWith.append(c.id) }
        case "WarDeclaration": if let c = state.civs.first(where: { $0.nation == name }) { side.warOns.append(c.id) }
        case "Embassy": side.embassy = true   // Unciv TradeOfferType.Embassy, name Constants.acceptEmbassy
        case "Agreement": if name == "Embassy" { side.embassy = true } else { side.openBorders = true }
        case "Treaty":
            switch name {
            case "Research Agreement": side.researchAgreement = true; side.researchAgreementCost = amount   // Unciv TradeOffer.amount: the cost
            case "Declaration of Friendship": side.friendship = true
            case "Defensive Pact": side.defensivePact = true
            default: side.peace = true
            }
        default: break
        }
    }
    return side
}

/// The class tag Unciv's Json writes on - and its reader needs for - every element of a TradeOffersList
static let tradeOfferClass = "com.unciv.logic.trade.TradeOffer"

/// A saved TradeOffersList's order (TradeRecord.ourTail, TradeOffer.evTailGive: every offer, in the order it was added) -
/// the names evOfferNames gives them: the offer's name, "Accept Embassy" for an embassy of either spelling.
private static func offerListOrder(_ offers: [[String: Any]]) -> [String] {
    var names: [String] = []
    for o in offers {
        let name = (o["name"] as? String) ?? "", type = (o["type"] as? String) ?? ""
        let n = type == "Embassy" || (type == "Agreement" && name == "Embassy") ? "Accept Embassy" : name
        if !names.contains(n) { names.append(n) }
    }
    return names
}

/// One side of a pending trade in Unciv's TradeOffer shape (name / type / amount / duration): TradeOffer(speed)'s
/// durations - dealDuration for a timed offer, peaceDealDuration for the Peace Treaty, -1 for an immediate one (ours
/// wrote Standard's 30 and 10 whatever the speed) - in the order the request's list holds them (getAvailableOffers'
/// order, then the offers added past it: `tail`, TradeOffer.evTailGive / evTailWant), one offer per resource with its
/// copies as the amount (TradeOffersList.add).
private static func tradeSideJSON(_ side: TradeSide, tail: [String], state: GameState, rs: Ruleset) -> [[String: Any]] {
    let deal = state.speed.dealDuration, peace = state.speed.peaceDealDuration
    var out: [(name: String, json: [String: Any])] = []
    func add(_ name: String, _ type: String, amount: Int = 1, duration: Int = -1) {
        out.append((name, ["class": tradeOfferClass, "name": name, "type": type, "amount": amount, "duration": duration]))
    }
    if side.embassy { add("Accept Embassy", "Embassy") }   // Unciv Constants.acceptEmbassy + TradeOfferType.Embassy
    if side.peace { add("Peace Treaty", "Treaty", duration: peace) }
    if side.openBorders { add("Open Borders", "Agreement", duration: deal) }
    if side.researchAgreement { add("Research Agreement", "Treaty", amount: side.researchAgreementCost, duration: deal) }
    if side.defensivePact { add("Defensive Pact", "Treaty", duration: deal) }
    if side.friendship { add("Declaration of Friendship", "Treaty", duration: 30) }
    var seen = Set<String>()
    for r in side.resources where seen.insert(r).inserted {
        add(r, rs.resources[r]?.resourceType == "Strategic" ? "Strategic_Resource" : "Luxury_Resource", amount: side.resources.filter { $0 == r }.count, duration: deal)
    }
    for (r, n) in side.stockpiles.sorted(by: { $0.key < $1.key }) where n > 0 { add(r, "Stockpiled_Resource", amount: n) }
    if side.gold > 0 { add("Gold", "Gold", amount: side.gold) }
    if side.goldPerTurn > 0 { add("Gold per turn", "Gold_Per_Turn", amount: side.goldPerTurn, duration: deal) }
    for cid in side.cities where state.city(cid) != nil { add(state.uncivCityId(cid), "City") }   // Unciv TradeLogic: TradeOffer(city.id, TradeOfferType.City), the id the file gives the city
    for x in side.introductions { if let c = state.civ(x) { add(c.nation, "Introduction") } }
    for w in side.warOns { if let c = state.civ(w) { add(c.nation, "WarDeclaration") } }
    for x in side.peaceWith { if let c = state.civ(x) { add(c.nation, "PeaceProposal") } }
    return uncivOfferOrder(out, name: { $0.name }, tail: tail).map(\.json)
}

// MARK: - Unciv map files (TileMap JSON: mapParameters + tileList + startingLocations, gzip+base64 like saves)

    static func isUncivMap(_ text: String) -> Bool {
        guard let data = decodeToJSONData(text), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["tileList"] != nil && root["civilizations"] == nil
    }
    /// Import a map saved by Unciv's map editor as one of our custom maps (starting locations become start positions).
    static func importMap(from text: String) throws -> CustomMap {
        guard let data = decodeToJSONData(text), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tileList = root["tileList"] as? [[String: Any]] else { throw ImportError.notUnciv }
        let fake: [String: Any] = ["tileMap": root, "civilizations": [], "gameParameters": ["mods": (root["mapParameters"] as? [String: Any])?["mods"] ?? []]]
        let state = try importGame(fake)
        // Re-derive the frame to place starting locations.
        guard let (frame, _, _) = frame(for: tileList.map { pos($0["position"]) }) else { throw ImportError.notUnciv }
        var starts: [StartingLocation] = []
        for sl in root["startingLocations"] as? [[String: Any]] ?? [] {
            let (x, y) = pos(sl["position"]); let o = frame.ours(x: x, y: y)
            let c = HexCoord.fromOffset(col: o.col, row: o.row)
            guard state.map.contains(c) else { continue }
            // Unciv stores the editor's "Any Civ" brush under the Spectator nation, and maps saved before
            // StartingLocation.Usage existed have no "usage" at all - those fall back to Usage.default (Player).
            let nation = sl["nation"] as? String ?? ""
            let usage = StartingLocation.Usage(rawValue: sl["usage"] as? String ?? "") ?? .player
            starts.append(StartingLocation(position: c, nation: nation == "Spectator" ? "" : nation, usage: usage))
        }
        // Unciv TileMap.description and mapParameters.seed / baseRuleset / mods travel with the map
        var custom = CustomMap(map: state.map, startingLocations: starts, description: state.settings.mapDescription, seed: state.settings.seed,
                               baseRuleset: state.settings.baseRuleset, mods: state.settings.mods)
        custom.parameters = state.settings
        // the map's units are not read into it (importGame finds none of their owners): only who owns each, as written
        for t in tileList {
            var owners: [Any?] = [(t["militaryUnit"] as? [String: Any])?["owner"], (t["civilianUnit"] as? [String: Any])?["owner"]]
            owners += ((t["airUnits"] as? [[String: Any]]) ?? []).map { $0["owner"] }
            custom.unitOwners += owners.compactMap { $0 }.map { ($0 as? String) ?? "" }
        }
        return custom
    }
    /// Export one of our custom maps as an Unciv `.map` (the editor's "Copy to clipboard" / "Save map" format).
    static func exportMap(_ m: CustomMap, name: String, zipped: Bool = true) -> String {
        var map = m.map
        map.assignContinents(.reassign)   // Unciv MapSaver.mapToSavedString: tileMap.assignContinents(Reassign)
        let state = GameState.editorState(map: map)
        // Unciv MapEditorSaveTab: `tileMap.description = descriptionTextField.text`; the map's own seed and ruleset
        state.settings.mapDescription = m.description
        state.settings.seed = m.seed
        state.settings.baseRuleset = m.baseRuleset
        state.settings.mods = m.mods
        if let p = m.parameters { state.settings.takeMapParameters(p) }   // the map's own MapParameters
        let root = exportJSON(state)
        guard var tileMap = root["tileMap"] as? [String: Any] else { return "" }
        var params = tileMap["mapParameters"] as? [String: Any] ?? [:]
        params["name"] = name
        tileMap["mapParameters"] = params
        let frame = Frame.forExport(width: m.map.width, height: m.map.height)
        // Unciv StartingLocation: {"position": …, "nation": …, "usage": …}; "Any Civ" is written as the Spectator nation.
        tileMap["startingLocations"] = m.startingLocations.map { sl -> [String: Any] in
            ["position": posJSON(frame.unciv(col: sl.position.offsetCol, row: sl.position.offsetRow)),
             "nation": sl.nation.isEmpty ? "Spectator" : sl.nation,
             "usage": sl.usage.rawValue]
        }
        // units and civ-specific tile fields are not part of a map file
        if var tiles = tileMap["tileList"] as? [[String: Any]] {
            for i in tiles.indices { tiles[i]["exploredBy"] = nil; tiles[i]["militaryUnit"] = nil; tiles[i]["civilianUnit"] = nil; tiles[i]["airUnits"] = nil }
            tileMap["tileList"] = tiles
        }
        guard let data = try? JSONSerialization.data(withJSONObject: tileMap, options: []) else { return "" }
        return encode(data, zipped: zipped)
    }

    // MARK: - export

    static func exportString(_ state: GameState, zipped: Bool = true) -> String {
        let root = exportJSON(state)
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []) else { return "" }
        return encode(data, zipped: zipped)
    }

    static func exportJSON(_ state: GameState) -> [String: Any] {
        let rs = state.rs
        let map = state.map
        let frame = Frame.forExport(width: map.width, height: map.height)
        func civKey(_ id: Int) -> String { state.civ(id)?.nation ?? "" }
        func hex(_ c: HexCoord) -> [String: Any] { posJSON(frame.unciv(col: c.offsetCol, row: c.offsetRow)) }

        // Tiles
        let cityAt: [HexCoord: City] = Dictionary(uniqueKeysWithValues: state.cities.map { ($0.coord, $0) })
        var tileList: [[String: Any]] = []
        // Unciv writes tileList in its own order (tileMap.values); a grid cell that is not a tile of the real map is skipped
        let tileOrder = map.uncivOrder.isEmpty ? map.tiles.indices.filter { !map.missing.contains($0) } : map.uncivOrder
        for i in tileOrder {
            let t = map.tiles[i]
            var tj: [String: Any] = ["position": hex(t.coord), "baseTerrain": t.baseTerrain, "terrainFeatures": t.features]
            tj["continent"] = t.continent   // Unciv Tile.continent: the stored id, -1 for water and impassable land
            if let nw = t.naturalWonder { tj["naturalWonder"] = nw }
            if let r = t.resource { tj["resource"] = r; tj["resourceAmount"] = rs.resources[r]?.resourceType == "Strategic" ? (t.resourceAmount > 0 ? t.resourceAmount : 2) : 0 }
            if let imp = t.improvement { tj["improvement"] = imp }
            if t.pillaged { tj["improvementIsPillaged"] = true }
            if t.roadPillaged { tj["roadIsPillaged"] = true }
            if let ip = t.improvementInProgress {
                var queue: [[String: Any]] = [["improvement": ip, "turnsToImprovement": t.improvementTurnsLeft]]
                if let next = t.queuedImprovement { queue.append(["improvement": next, "turnsToImprovement": t.queuedImprovementTurns]) }
                tj["improvementQueue"] = queue
            }
            if let ro = t.roadOwner { tj["roadOwner"] = civKey(ro) }
            if !t.history.isEmpty { tj["history"] = Dictionary(uniqueKeysWithValues: t.history.map { (String($0.key - 1), [$0.value.owner.flatMap { civKey($0) } ?? "", $0.value.center] as [Any]) }) }
            tj["roadStatus"] = t.railroad ? "Railroad" : (t.roads ? "Road" : "None")
            if t.riverEdges.contains(HexCoord.dirS) { tj["hasBottomRiver"] = true }
            if t.riverEdges.contains(HexCoord.dirSW) { tj["hasBottomLeftRiver"] = true }
            if t.riverEdges.contains(HexCoord.dirSE) { tj["hasBottomRightRiver"] = true }
            let explored = state.civs.filter { !$0.isBarbarian && $0.explored.contains(t.coord) }.map { $0.nation }
            if !explored.isEmpty { tj["exploredBy"] = explored }
            _ = cityAt
            let here = state.units(at: t.coord)
            if let mil = here.first(where: { $0.isMilitary && !$0.def.isAir }) { tj["militaryUnit"] = unitJSON(mil, state, hex: hex) }
            if let civilian = here.first(where: { $0.isCivilian }) { tj["civilianUnit"] = unitJSON(civilian, state, hex: hex) }
            let air = here.filter { $0.def.isAir }
            if !air.isEmpty { tj["airUnits"] = air.map { unitJSON($0, state, hex: hex) } }
            tileList.append(tj)
        }
        let mapParameters: [String: Any] = [
            "name": "", "type": state.settings.mapType, "shape": (state.settings.mapShape == "Rectangular" ? "Rectangular" : state.settings.mapShape),
            "mapSize": map.uncivSize.map { ["name": $0.name, "radius": $0.radius, "width": $0.width, "height": $0.height] as [String: Any] }
                ?? ["name": "Custom", "radius": MapGenerator.equivalentRadius(tiles: map.realTileCount), "width": map.width, "height": map.height],
            "mapResources": state.settings.resourceSetting, "noRuins": !state.settings.ancientRuins, "noNaturalWonders": !state.settings.naturalWonders,
            "worldWrap": map.wrapX, "strategicBalance": state.settings.strategicBalance, "legendaryStart": state.settings.legendaryStart,
            "baseRuleset": state.settings.baseRuleset, "mods": state.settings.mods, "seed": Int64(truncatingIfNeeded: state.settings.seed),
            "tilesPerBiomeArea": state.settings.tilesPerBiomeArea, "maxCoastExtension": state.settings.maxCoastExtension, "elevationExponent": state.settings.elevationExponent,
            "mirroring": "None", "temperatureintensity": state.settings.temperatureIntensity, "vegetationRichness": state.settings.vegetationRichness, "rareFeaturesRichness": state.settings.rareFeaturesRichness,
            "resourceRichness": 0.1, "waterThreshold": state.settings.waterThreshold, "temperatureShift": state.settings.temperatureShift, "createdWithVersion": "Epochs",
        ]
        let startingLocations: [[String: Any]] = state.civs.filter { !$0.isBarbarian && !$0.isSpectator }.compactMap { civ in
            guard let start = civ.startingLocation else { return nil }
            return ["position": hex(start), "nation": civ.nation]   // Unciv StartingLocation.usage defaults to Usage.Player - omit it
        }
        let tileMap: [String: Any] = ["mapParameters": mapParameters, "tileList": tileList, "startingLocations": startingLocations, "description": state.settings.mapDescription]

        // Civilizations
        var civs: [[String: Any]] = []
        var religions: [String: Any] = [:]
        for civ in state.civs where !civ.isSpectator || civ.isPlayer {
            func notificationJSON(_ item: NotificationItem) -> [String: Any] {
            
                var n: [String: Any] = ["text": item.text]
                if item.meta.category != .General { n["category"] = item.meta.category.rawValue }
                if !item.meta.icons.isEmpty { n["icons"] = item.meta.icons }
                let actions: [[String: Any]] = item.meta.actions.map { a in
                    switch a {
                    case .location(let c): return ["LocationAction": ["location": hex(c)]]
                    case .city(let c): return ["CityAction": ["city": hex(c)]]
                    case .tech(let t): return ["TechAction": ["techName": t]]
                    case .diplomacy(let civName): return ["DiplomacyAction": ["otherCivName": civName, "showTrade": false]]
                    case .diplomacyTrade(let civName): return ["DiplomacyAction": ["otherCivName": civName, "showTrade": true]]
                    case .unit(let c, let id): return ["MapUnitAction": ["location": hex(c), "id": id]]
                    case .civilopedia(let link): return ["CivilopediaAction": ["link": link]]
                    case .overview(let page, let sel): return ["OverviewAction": ["page": page, "select": sel]]
                    case .policy(let sel): return ["PolicyAction": ["select": sel]]
                    case .espionage: return ["EspionageAction": [:]]
                    case .religion(let r): return ["ReligionAction": ["religionName": r]]
                    case .link(let u): return ["LinkAction": ["url": u]]
                    case .promoteUnit(let name, let c, let id): return ["PromoteUnitAction": ["name": name, "location": hex(c), "id": id]]
                    case .mayaLongCount: return ["MayaLongCountAction": [:]]
                    }
                }
                if !actions.isEmpty { n["actions"] = actions }
                return n
            }
            var cj: [String: Any] = [
                "playerType": civ.isPlayer && !civ.isSpectator ? "Human" : (civ.isSpectator ? "Human" : "AI"), "playerId": civ.playerUserId ?? "", "gold": Int(civ.gold),
                "playerMinutesBeforeForceResign": civ.playerMinutesBeforeForceResign,
                "totalTurnTimeSeconds": civ.totalTurnTimeSeconds, "turnsPlayedAsHuman": civ.turnsPlayedAsHuman,
                "civName": civ.nation, "civID": civ.nation, "citiesCreated": civ.citiesCreated, "naturalWonders": civ.seenNaturalWonders.sorted(),
                "resourceStockpiles": civ.resourceStockpiles, "leaderTitle": civ.leaderTitle ?? "",   // Unciv Civilization.leaderTitle is a non-null String defaulting to ""
                "notificationsLog": civ.notificationLog.map { e -> [String: Any] in ["turn": e.turn - 1, "notifications": e.items.map(notificationJSON)] },
                "cityStatePersonality": civ.cityStatePersonality, "cityStateUniqueUnit": civ.cityStateUniqueUnit as Any, "cityStateResource": civ.cityStateResource as Any, "hasEverOwnedOriginalCapital": civ.hasEverOwnedOriginalCapital,
            ]
            // Unciv Civilization.exploredRegion: `{}` while it is zero, a zero coordinate left out
            func regionPoint(_ p: ExploredRegion.Point) -> [String: Any] { var d: [String: Any] = [:]; if p.x != 0 { d["x"] = Double(p.x) }; if p.y != 0 { d["y"] = Double(p.y) }; return d }
            cj["exploredRegion"] = civ.exploredRegion.isZero ? [String: Any]() : ["topLeft": regionPoint(civ.exploredRegion.topLeft), "bottomRight": regionPoint(civ.exploredRegion.bottomRight)]
            var techsToResearch = civ.techQueue
            if let cur = civ.currentTech { techsToResearch.insert(cur, at: 0) }
            let techsInProgress = civ.techsInProgress
            cj["tech"] = ["techsResearched": civ.techs.sorted(), "techsToResearch": techsToResearch, "techsInProgress": techsInProgress, "freeTechs": civ.freeTechs, "scienceFromResearchAgreements": Int(civ.scienceFromResearchAgreements), "repeatingTechsResearched": civ.futureTechs, "scienceOfLast8Turns": civ.scienceOfLast8Turns, "overflowScience": civ.overflowScience, "goldPercentConvertedToScience": civ.goldPercentConvertedToScience]
            cj["policies"] = ["adoptedPolicies": Array(civ.policies.union(civ.openBranches)), "freePolicies": civ.freePolicies, "storedCulture": Int(civ.cultureStored), "numberOfAdoptedPolicies": civ.paidPolicyCount, "shouldOpenPolicyPicker": civ.shouldOpenPolicyPicker]
            if civ.cultureOfLast8Turns.count == 8, var pol = cj["policies"] as? [String: Any] { pol["cultureOfLast8Turns"] = civ.cultureOfLast8Turns; cj["policies"] = pol }
            if !civ.lastSeenImprovement.isEmpty {   // Unciv LastSeenImprovement.write: HexCoord.toPrettyString() keys
                cj["lastSeenImprovement"] = Dictionary(uniqueKeysWithValues: civ.lastSeenImprovement.map { (c, n) -> (String, Any) in let p = frame.unciv(col: c.offsetCol, row: c.offsetRow); return ("(\(p.x),\(p.y))", n) })
            }
            if !civ.attacksSinceTurnStart.isEmpty {   // Unciv Civilization.HistoricalAttackMemory: attackingUnit (omitted when null), source, target
                cj["attacksSinceTurnStart"] = civ.attacksSinceTurnStart.map { m -> [String: Any] in var d: [String: Any] = ["source": hex(m.source), "target": hex(m.target)]; if let n = m.attackingUnit { d["attackingUnit"] = n }; return d }
            }
            if !civ.temporaryUniques.isEmpty { cj["temporaryUniques"] = civ.temporaryUniques.map { var d: [String: Any] = ["unique": $0.unique, "turnsLeft": $0.turnsLeft]; if let n = $0.sourceObjectName { d["sourceObjectName"] = n }; if let t = $0.sourceObjectType { d["sourceObjectType"] = t }; return d } }
            cj["goldenAges"] = ["storedHappiness": Int(civ.goldenAgePoints), "turnsLeftForCurrentGoldenAge": civ.goldenAgeTurns, "numberOfGoldenAges": civ.goldenAgesHad]
            cj["greatPeople"] = ["greatPersonPointsCounter": civ.greatPersonPoints.mapValues { Int($0) }, "pointsForNextGreatPersonCounter": civ.pointsForNextGreatPersonCounter, "pointsForNextGreatGeneralCounter": civ.pointsForNextGreatGeneralCounter, "greatGeneralPointsCounter": civ.greatGeneralPoints, "freeGreatPeople": civ.freeGreatPeople,
                                 "mayaLimitedFreeGP": civ.mayaLimitedFreeGP, "longCountGPPool": civ.longCountGPPool]
            var rm: [String: Any] = ["storedFaith": Int(civ.faithStored), "religionState": civ.religionName != nil ? (civ.religionEnhanced ? "EnhancedReligion" : "Religion") : (civ.pantheonBelief != nil ? "Pantheon" : "None"), "freeBeliefs": civ.freeBeliefsByType]
            if civ.religionName != nil || civ.pantheonBelief != nil {
                let name = civ.religionName ?? civ.pantheonBelief!   // Unciv names a pantheon after its belief
                let founder = civ.religionBeliefs.filter { rs.beliefs[$0]?.type == "Founder" || rs.beliefs[$0]?.type == "Enhancer" }
                var follower = civ.pantheonBelief.map { [$0] } ?? []
                follower += civ.religionBeliefs.filter { (rs.beliefs[$0]?.type == "Follower" || rs.beliefs[$0]?.type == "Pantheon") && !follower.contains($0) }
                var rj: [String: Any] = ["name": name, "foundingCivName": civ.nation, "founderBeliefs": founder, "followerBeliefs": follower]
                if civ.religionName != nil { rj["displayName"] = civ.religionDisplayName ?? name }
                rm["religion"] = rj
                religions[name] = rj
                if civ.religionName != nil, let p = civ.pantheonBelief { religions[p] = ["name": p, "foundingCivName": civ.nation, "founderBeliefs": [String](), "followerBeliefs": [p]] as [String: Any] }   // the pantheon keeps its own entry
            }
            cj["religionManager"] = rm
            cj["victoryManager"] = ["currentsSpaceshipParts": civ.spaceshipParts, "hasEverWonDiplomaticVote": civ.hasEverWonDiplomaticVote]
            cj["ruinsManager"] = ["lastChosenRewards": civ.lastRuinRewards]
            cj["civConstructions"] = ["boughtItemsWithIncreasingPrice": civ.boughtWithIncreasingPrice, "builtItemsWithIncreasingCost": civ.builtItemsWithIncreasingCost,
                                      "freeBuildings": Dictionary(civ.freeBuildingsOfCities.map { (state.uncivCityId($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }),
                                      "freeStatBuildingsProvided": civ.freeStatBuildingsProvided.mapValues { $0.map { state.uncivCityId($0) } },
                                      "freeSpecificBuildingsProvided": civ.freeSpecificBuildingsProvided.mapValues { $0.map { state.uncivCityId($0) } }] as [String: Any]
            cj["totalCultureForContests"] = civ.totalCultureForContests; cj["totalFaithForContests"] = civ.totalFaithForContests; cj["numMinorCivsAttacked"] = civ.numMinorCivsAttacked
            cj["espionageManager"] = ["spyList": civ.spies.map { spy -> [String: Any] in
                var sj: [String: Any] = ["name": spy.name, "rank": spy.rank, "action": spy.action, "turnsRemainingForAction": spy.turnsRemaining, "progressTowardsStealingTech": Int(spy.progress)]
                if let cid = spy.cityId, let c = state.city(cid) { sj["location"] = hex(c.coord) }
                return sj
            }, "erasSpyEarnedFor": civ.spiesGranted.sorted(), "dismissedShouldMoveSpies": civ.dismissedShouldMoveSpies]
            cj["questManager"] = ["assignedQuests": civ.quests.filter { $0.completedBy == nil }.map { q -> [String: Any] in
                let data = state.uncivQuestData(q)
                return ["questName": q.name, "assigner": civ.nation, "assignee": q.assigneeId.flatMap { state.civ($0)?.nation } ?? "", "assignedOnTurn": q.startTurn - 1, "data1": data.data1, "data2": data.data2]
            }, "globalQuestCountdown": civ.globalQuestCountdown, "unitsToKillForCiv": Dictionary(civ.unitsToKillForCiv.compactMap { k, v in state.civ(k).map { ($0.nation, v) } }, uniquingKeysWith: { a, _ in a }), "unitsKilledFromCiv": Dictionary(civ.unitsKilledFromCiv.compactMap { k, v in state.civ(k).map { ($0.nation, Dictionary(v.compactMap { hk, hv in state.civ(hk).map { ($0.nation, hv) } }, uniquingKeysWith: { a, _ in a })) } }, uniquingKeysWith: { a, _ in a }), "individualQuestCountdown": Dictionary(civ.individualQuestCountdown.compactMap { k, v in state.civ(k).map { ($0.nation, v) } }, uniquingKeysWith: { a, _ in a })]
            cj["notifications"] = civ.notificationItems.map(notificationJSON)
            // Unciv resolves every alert against its own AlertType enum and refuses the whole save on an unknown
            // one, so our TradeRequest - which Unciv has no name for - is left out rather than exported.
            // Unciv keeps a demand and a Declaration of Friendship for their receiver as popupAlerts (the importer reads them
            // back into pendingDemands / pendingOffers): ours waiting for an answer go there, in the order they were made
            // Each value as Unciv writes it (uncivAlertValue: a civ by its name, a recaptured civilian by its tile...)
            var alerts: [(type: String, value: String)] = civ.popupAlerts.filter { $0.type != .TradeRequest }.map {
                ($0.type.rawValue, state.uncivAlertValue($0, uncivPos: { c in frame.unciv(col: c.offsetCol, row: c.offsetRow) }))
            }
            var waiting: [(id: Int, type: String, value: String)] = state.pendingDemands.filter { $0.to == civ.id }.compactMap { d in state.civ(d.from).map { (d.id, d.demand.demandAlert.rawValue, $0.nation) } }
            waiting += state.pendingOffers.filter { $0.to == civ.id && $0.give.friendship && $0.want.friendship }.compactMap { o in state.civ(o.from).map { (o.id, AlertType.DeclarationOfFriendship.rawValue, $0.nation) } }
            // a human's own alert for it is already there
            for w in waiting.sorted(by: { $0.id < $1.id }) where !alerts.contains(where: { $0.type == w.type && $0.value == w.value }) { alerts.append((w.type, w.value)) }
            cj["popupAlerts"] = alerts.map { ["type": $0.type, "value": $0.value] }
            cj["flagsCountdown"] = civ.civFlags
            if !civ.disabledCivConstructions.isEmpty { cj["disabledCityConstructions"] = Array(civ.disabledCivConstructions).sorted() }
            let ids: [String: String] = ["Score": "S", "Population": "N", "Growth": "C", "Production": "P", "Gold": "G", "Territory": "T", "Force": "F", "Happiness": "H", "Technologies": "W", "Culture": "A", "Tiles Explored": "E"]
            var history: [String: String] = [:]
            for (turn, row) in civ.statsHistory { history["\(turn)"] = GameState.allRankingTypes.compactMap { t in row[t].map { "\(ids[t] ?? "S")\($0)" } }.joined() }
            cj["statsHistory"] = history
            var diplo: [String: Any] = [:]
            // Unciv's meeting is mutual (DiplomacyFunctions.makeCivilizationsMeet gives each side a DiplomacyManager), a
            // Spectator's too: a civ one side's diplomacy names must name it back, or Unciv's loader stops at the missing
            // manager (CivInfoTransientCache.updateCityStateBonuses' `cityState.getDiplomacyManager(civInfo)!!` for the
            // Spectator, whose own managers were written while no civ's had one for it)
            var others = civ.metCivs
            for o in state.civs where o.id != civ.id && o.metCivs.contains(civ.id) { others.insert(o.id) }
            for otherId in others.sorted() {   // Set<Int>: kayıt sırası sabit olsun
                guard let other = state.civ(otherId), !other.isBarbarian, otherId != civ.id else { continue }
                var d: [String: Any] = ["otherCivName": other.nation, "diplomaticStatus": civ.isAtWar(with: otherId) ? "War" : (civ.defensivePacts.contains(otherId) ? "DefensivePact" : (civ.isCityState && other.protectedCityStates.contains(civ.id) ? "Protector" : "Peace"))]
                var mods: [String: Double] = [:]
                for (k, v) in civ.opinions[otherId] ?? [:] { mods[k] = v }
                d["diplomaticModifiers"] = mods
                if let ra = civ.totalOfScienceDuringRA[otherId], ra != 0 { d["totalOfScienceDuringRA"] = ra }   // Unciv DiplomacyManager.totalOfScienceDuringRA
                var flags: [String: Int] = civ.diploFlags[otherId] ?? [:]
                flags["PeaceTreaty"] = nil   // Unciv DiplomacyFlags has no PeaceTreaty entry - the treaty goes into `trades` below
                d["flagsCountdown"] = flags
                if civ.isCityState { d["influence"] = civ.influence[otherId] ?? 0 }
                if state.hasOpenBorders(civ.id, in: otherId) { d["hasOpenBorders"] = true }   // Unciv: civInfo may enter otherCiv
                if let sm = civ.smoothedOpinion[otherId] { d["smoothedOpinionOfOtherCiv"] = sm }
                if let csm = civ.cachedSmoothedOpinion[otherId] { d["cachedSmoothedOpinionOfOtherCiv"] = csm }
                // Unciv DiplomacyManager.trades: this civ's copy of every trade with the other civ, in the order they were
                // added, each with every offer as that copy holds it - GameState.currentTrades, what the Trades overview
                // lists. A Peace Treaty traded together with a resource or gold per turn sits in that trade's two lists
                // (ourOffers at turnsToPeaceTreaty, theirOffers at peaceTreatyTheirOffersLeft - a PeaceProposal giver's one
                // offer in both lists written twice, as Unciv's save writes it), so the reloaded game cuts it short with its
                // trade (removeUntenableTrades' remakePeaceTreaty) and announces its end with the trade's; a treaty
                // remakePeaceTreaty made at 0 has both offers at 0 until this civ's next end of turn drops it; an immediate
                // offer (gold, an embassy, a city...) stays at -1 until this civ's next end of turn drops its trade. Ours
                // wrote the treaty as a trade of its own ahead of the deals, and left the immediate offers out.
                // Each offer carries its class, as Unciv's Json writes an element of a TradeOffersList (an ArrayList subclass
                // whose element type it cannot know): without it Unciv's reader casts a JsonValue to TradeOffer and throws -
                // no file of ours with a trade in it could be opened
                d["trades"] = (state.currentTrades(civ, withText: false)[otherId] ?? []).map { row -> [String: Any] in
                    func json(_ o: TradeOverviewOffer) -> [String: Any] { ["class": UncivSave.tradeOfferClass, "name": o.name, "type": o.type, "amount": o.amount, "duration": o.duration] }
                    return ["ourOffers": row.ours.map(json), "theirOffers": row.theirs.map(json)]
                }
                diplo[other.nation] = d
            }
            cj["diplomacy"] = diplo
            cj["tradeRequests"] = state.pendingOffers.filter { $0.to == civ.id && !$0.isFriendshipRequest }.compactMap { offer -> [String: Any]? in
                guard let proposer = state.civ(offer.from) else { return nil }
                return ["requestingCiv": proposer.nation,
                        "trade": ["ourOffers": tradeSideJSON(offer.want, tail: offer.evTailWant, state: state, rs: rs), "theirOffers": tradeSideJSON(offer.give, tail: offer.evTailGive, state: state, rs: rs)]]
            }
            var prox: [String: String] = [:]   // Unciv Civilization.proximity: it is not recomputed on load
            for other in state.civs where other.id != civ.id && !other.isBarbarian && !other.isSpectator {
                switch state.proximity(civ.id, other.id) {
                case .neighbors: prox[other.nation] = "Neighbors"
                case .close: prox[other.nation] = "Close"
                case .far: prox[other.nation] = "Far"
                case .distant: prox[other.nation] = "Distant"
                case .none: break
                }
            }
            cj["proximity"] = prox
            // Cities
            var cities: [[String: Any]] = []
            for city in state.cities(of: civ.id) {
                var queue: [String] = []
                if let p = city.currentProduction { queue.append(p.name) } else if !city.convertProductionTo.isEmpty { queue.append(city.convertProductionTo) }
                queue += city.productionQueue.map { $0.name }
                if city.currentProduction != nil && !city.convertProductionTo.isEmpty { queue.append(city.convertProductionTo) }   // the trailing perpetual
                var inProgress: [String: Int] = city.inProgressConstructions
                if let p = city.currentProduction, city.productionStored > 0 { inProgress[p.name] = Int(city.productionStored) }
                var flags: [String: Int] = [:]
                if city.resistanceTurns > 0 { flags["Resistance"] = city.resistanceTurns }
                if city.wltkdTurns > 0 { flags["WeLoveTheKing"] = city.wltkdTurns }
                if city.resourceDemandCooldown >= 0 { flags["ResourceDemand"] = city.resourceDemandCooldown }
                var rj: [String: Any] = ["pressures": city.religionPressure.mapValues { Int($0) }, "isBlockedHolyCity": city.holyCityOf != nil && !city.isHolyCity]
                if let h = city.holyCityOf { rj["religionThisIsTheHolyCityOf"] = h }   // a blocked holy city keeps its religion in Unciv too
                if !city.religionsAtSomePointAdopted.isEmpty { rj["religionsAtSomePointAdopted"] = city.religionsAtSomePointAdopted.sorted() }
                let cityJSON: [String: Any] = [
                    "location": hex(city.coord), "id": state.uncivCityId(city.id), "name": city.name,   // Unciv City.id (uncivCityId)
                    "foundingCiv": city.originalOwner < 0 ? "" : (state.civ(city.originalOwner)?.nation ?? civ.nation), "previousOwner": state.civ(city.previousOwner)?.nation ?? "", "turnAcquired": city.acquiredTurn, "health": city.health,
                    "population": ["population": city.population, "foodStored": Int(city.foodStored), "specialistAllocations": city.specialists],
                    "cityConstructions": ["builtBuildings": city.buildings, "inProgressConstructions": inProgress, "constructionQueue": queue, "productionOverflow": city.productionOverflow, "currentConstructionIsUserSet": city.currentConstructionIsUserSet,
                                          "freeBuildingsProvidedFromThisCity": city.freeBuildingsProvidedFromThisCity.isEmpty ? [String: [String]]() : [state.uncivCityId(city.id): city.freeBuildingsProvidedFromThisCity]] as [String: Any],
                    "expansion": ["cultureStored": Int(city.expansionCulture)],
                    "religion": rj,
                    "tiles": city.tiles.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }).map(hex), "workedTiles": city.workedTiles.map(hex), "lockedTiles": city.lockedTiles.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }).map(hex),
                    "isBeingRazed": city.razing, "isPuppet": city.isPuppet, "isOriginalCapital": city.isOriginalCapital, "avoidGrowth": city.avoidGrowth, "cityAIFocus": city.cityFocus,
                    "demandedResource": city.demandedResource, "flagsCountdown": flags, "manualSpecialists": city.manualSpecialists, "hasSoldBuildingThisTurn": city.hasSoldBuildingThisTurn, "attackedThisTurn": city.attackedThisTurn,
                    "disabledConstructions": Array(city.disabledConstructions).sorted(), "shouldReassignPopulation": city.shouldReassignPopulation,
                    "unitToPromotions": Dictionary(uniqueKeysWithValues: city.defaultPromotions.keys.compactMap { k in state.savedUnitPromotions(city, k).map { (k, ["XP": $0.xp, "promotions": $0.promotions, "numberOfPromotions": $0.numberOfPromotions] as [String: Any]) } }), "unitShouldUseSavedPromotion": Dictionary(uniqueKeysWithValues: city.useDefaultPromotions.map { ($0, true) }),
                ]
                cities.append(cityJSON)
            }
            cj["cities"] = cities
            civs.append(cj)
        }

        let gameParameters: [String: Any] = [
            "difficulty": state.settings.difficulty, "speed": state.settings.speed,
            // Unciv writes gameParameters.players as the game was set up (GameStarter never changes it); a game with no
            // seats (an old save of ours) writes its major civs
            "players": state.settings.players.isEmpty ? state.civs.filter { $0.isMajor }.map { ["chosenCiv": $0.nation, "playerType": $0.isPlayer ? "Human" : "AI", "playerId": $0.playerUserId ?? ""] }
                : state.settings.players.map { ["chosenCiv": $0.chosenCiv, "playerType": $0.isHuman ? "Human" : "AI", "playerId": $0.playerId] },
            // Unciv's GameStarter reads these and leaves them as set up (GameStarter.kt:276-346 - a random count is drawn
            // into a local), and GameSetupInfo(gameInfo) clones them for Start new game; a game with no seats (an old
            // save of ours) writes the city-states it has
            "numberOfCityStates": state.settings.players.isEmpty ? state.civs.filter { $0.isCityState }.count : (state.settings.cityStateCount >= 0 ? state.settings.cityStateCount : 6),
            "randomNumberOfPlayers": state.settings.randomNumberOfPlayers, "minNumberOfPlayers": state.settings.minNumberOfPlayers, "maxNumberOfPlayers": state.settings.maxNumberOfPlayers,
            "randomNumberOfCityStates": state.settings.randomNumberOfCityStates, "minNumberOfCityStates": state.settings.minNumberOfCityStates, "maxNumberOfCityStates": state.settings.maxNumberOfCityStates,
            "enableRandomNationsPool": state.settings.enableRandomNationsPool, "randomNationsPool": state.settings.randomNationsPool,
            "godMode": state.settings.godMode, "anyoneCanSpectate": state.settings.anyoneCanSpectate,
            "noCityRazing": state.settings.noCityRazing, "noBarbarians": !state.settings.barbarians, "ragingBarbarians": state.settings.ragingBarbarians,
            "oneCityChallenge": state.settings.oneCityChallenge, "nuclearWeaponsEnabled": state.settings.nuclearWeaponsEnabled, "espionageEnabled": state.settings.espionageEnabled,
            "noStartBias": state.settings.noStartBias, "shufflePlayerOrder": state.settings.shufflePlayerOrder,
            // Unciv's victoryTypes is a list, filled in the ruleset's order (NewGameScreen, quickstartNewGame's selectableVictories);
            // ours is a set, written in that order (a victory the ruleset lacks after it) where it was alphabetical
            "victoryTypes": rs.victories.map(\.name).filter { state.settings.victoryTypes.contains($0) } + state.settings.victoryTypes.subtracting(rs.victories.map(\.name)).sorted(), "startingEra": state.settings.startingEra.isEmpty ? rs.ancientEra.name : state.settings.startingEra,
            "isOnlineMultiplayer": state.settings.isOnline, "baseRuleset": state.settings.baseRuleset, "mods": state.settings.mods,
            "maxTurns": state.settings.maxTurns,
        ]
        let encampments: [[String: Any]] = state.encampments.map { ["position": hex($0.position), "countdown": $0.countdown, "spawnedUnits": $0.spawnedUnits, "destroyed": $0.destroyed] }
        var root: [String: Any] = [
            "version": ["number": compatibilityNumber, "createdWith": createdWith],
            "civilizations": civs, "barbarians": ["encampments": encampments], "religions": religions,
            "difficulty": state.settings.difficulty, "tileMap": tileMap, "gameParameters": gameParameters,
            "turns": state.turn - 1,   // Unciv counts turns from 0
            "oneMoreTurnMode": state.oneMoreTurnMode, "currentPlayer": state.currentHuman.nation,
            "currentTurnStartTime": Int(state.currentTurnStartTime > 0 ? state.currentTurnStartTime : Date().timeIntervalSince1970 * 1000), "gameId": state.settings.gameId ?? UUID().uuidString, "checksum": "",
            "diplomaticVictoryVotesCast": Dictionary(uniqueKeysWithValues: state.diplomaticVictoryVotesCast.compactMap { k, v -> (String, Any)? in guard let voter = state.civ(k) else { return nil }; return (voter.nation, v >= 0 ? (state.civ(v)?.nation ?? NSNull()) : NSNull()) }), "diplomaticVictoryVotesProcessed": state.diplomaticVictoryVotesProcessed, "historyStartTurn": state.historyStartTurn - 1, "unitNamesTaken": Array(state.unitNamesTaken).sorted(),
        ]
        if let v = state.victoryData, let winner = state.civ(v.winningCiv) { root["victoryData"] = ["winningCiv": winner.nation, "victoryType": v.victoryType, "victoryTurn": v.victoryTurn] }
        return root
    }

    /// Unciv MapUnit.action and MapUnit.automated for our unit's order (the save and the a state comparison write the same)
    static func uncivAction(_ u: Unit, _ state: GameState) -> (action: String?, automated: Bool) {
        var action: String? = nil
        var automated = false
        switch u.order {
        case .fortify: action = "Fortify"
        case .fortifyUntilHealed: action = "Fortify until healed"
        case .sleep: action = "Sleep"
        case .sleepUntilHealed: action = "Sleep until healed"
        case .explore: action = "Explore"   // Unciv UnitActions Explore sets only `unit.action`
        case .automate: automated = true
        case .guardPost: action = "Guard"
        case .connectRoad: automated = true; action = "Connect road"   // Unciv UnitActionType.ConnectRoad, as OverlayButtonData sets it
        case .moveTo(let c):
            let p = Frame.forExport(width: state.map.width, height: state.map.height).unciv(col: c.offsetCol, row: c.offsetRow); action = "moveTo \(p.x),\(p.y)"
        default: break
        }
        if u.automated { automated = true }
        if u.isSetUp { action = "Set up" }   // Unciv UnitActionType.SetUp.value: isSetUpForSiege() compares with it
        return (action, automated)
    }

    private static func unitJSON(_ u: Unit, _ state: GameState, hex: (HexCoord) -> [String: Any]) -> [String: Any] {
        let (action, automated) = uncivAction(u, state)
        var j: [String: Any] = [
            "owner": state.civ(u.civId)?.nation ?? "", "name": u.name, "currentMovement": u.movementLeft, "health": u.health, "id": u.id,
            "automated": automated, "attacksThisTurn": u.attacksThisTurn, "due": u.due,
            "promotions": ["XP": u.currentXP, "promotions": u.promotions, "numberOfPromotions": u.promotionNumber], "turnsFortified": u.turnsFortified,
            "movementMemories": u.movementMemories.map { ["position": hex($0.coord), "type": $0.type] as [String: Any] }, "mostRecentMoveType": u.mostRecentMoveType,
        ]
        if !u.attacksSinceTurnStart.isEmpty { j["attacksSinceTurnStart"] = u.attacksSinceTurnStart.map { hex($0) } }
        if let a = action { j["action"] = a }
        if u.escorting { j["escorting"] = true }
        if !u.statuses.isEmpty { j["statusMap"] = Dictionary(uniqueKeysWithValues: u.statuses.map { ($0.key, ["name": $0.key, "turnsLeft": $0.value] as [String: Any]) }) }
        if let o = state.civ(u.originalCiv), o.id != u.civId { j["originalOwner"] = o.nation }
        if let r = u.religion { j["religion"] = r }
        if u.isTransported { j["isTransported"] = true }
        if case .connectRoad(let dest) = u.order { j["automatedRoadConnectionDestination"] = hex(dest) }
        if u.religiousStrengthLost > 0 { j["religiousStrengthLost"] = u.religiousStrengthLost }
        if let n = u.customName { j["instanceName"] = n }
        if !u.abilityToTimesUsed.isEmpty { j["abilityToTimesUsed"] = u.abilityToTimesUsed }   // Unciv MapUnit.abilityToTimesUsed
        return j
    }
}
