// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv MapSize predefined sizes (radius for hexagonal maps, width × height for rectangular ones).
enum MapSizePreset: String, CaseIterable {
    case Tiny, Small, Medium, Large, Huge
    /// Unciv MapSize.Predefined.policyCostPerCityModifier
    var policyCostPerCityModifier: Double { switch self { case .Large: return 0.075; case .Huge: return 0.05; default: return 0.1 } }
    var radius: Int { switch self { case .Tiny: return 10; case .Small: return 15; case .Medium: return 20; case .Large: return 30; case .Huge: return 40 } }
    var width: Int { switch self { case .Tiny: return 23; case .Small: return 33; case .Medium: return 44; case .Large: return 66; case .Huge: return 87 } }
    var height: Int { switch self { case .Tiny: return 15; case .Small: return 21; case .Medium: return 29; case .Large: return 43; case .Huge: return 57 } }
}

/// Unciv TileMap.mapParameters' `mapSize` (MapSize: name, radius, width, height) and `shape`: the size a map was made
/// with, which is not the grid we keep it in - a rectangular map's odd columns stick out half a row, so the grid is one
/// row taller, and a hexagonal one leaves its corners empty. Everything Unciv measures by mapParameters reads this.
struct UncivMapSize: Codable, Equatable {
    /// Unciv MapSize.name: a predefined size, "Custom" or "Auto"
    var name: String = "Custom"
    var radius: Int = 0
    var width: Int = 0
    var height: Int = 0
    /// Unciv MapParameters.shape: "Rectangular", "Hexagonal" or "Flat Earth Hexagonal"
    var shape: String = "Rectangular"

    init(name: String, radius: Int, width: Int, height: Int, shape: String) {
        self.name = name; self.radius = radius; self.width = width; self.height = height; self.shape = shape
    }
    /// Unciv MapSize(Predefined)
    init(preset: MapSizePreset, shape: String) {
        self.init(name: preset.rawValue, radius: preset.radius, width: preset.width, height: preset.height, shape: shape)
    }
    /// Unciv MapSize(radius): a custom size, width and height from HexMath.getEquivalentRectangularSize (setNewRadius)
    init(radius: Int, shape: String) {
        let size = HexMath.equivalentRectangularSize(radius)
        self.init(name: "Custom", radius: radius, width: size.width, height: size.height, shape: shape)
    }
    /// Unciv MapSize(width, height): a custom size, radius from HexMath.getEquivalentHexagonalRadius
    init(width: Int, height: Int, shape: String) {
        self.init(name: "Custom", radius: HexMath.equivalentHexagonalRadius(width: width, height: height), width: width, height: height, shape: shape)
    }

    /// Unciv MapShape.hexagonal or MapShape.flatEarth
    var isHexagonal: Bool { shape == "Hexagonal" || shape == "Flat Earth Hexagonal" }
    /// Unciv MapParameters.numberOfTiles: `1 + 3r(r-1)` on a hexagonal map - not its real count, `1 + 3r(r+1)` - else width × height
    var numberOfTiles: Int { isHexagonal ? 1 + 3 * radius * (radius - 1) : width * height }
    /// Unciv MapSize.getPredefinedOrNextSmaller
    var predefinedOrNextSmaller: MapSizePreset {
        if name != "Custom" && name != "Auto" { return MapSizePreset(rawValue: name) ?? .Tiny }   // Predefined.safeValueOf
        for predef in MapSizePreset.allCases.reversed() where radius >= predef.radius { return predef }
        return .Tiny
    }
}
