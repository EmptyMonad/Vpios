// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// =====================================================================================
// Unciv `GameContext.stateBasedRandom` karşılığı.
//
//   Kotlin: fun stateBasedRandom(caller: String, seed: Int = 31) =
//               Random(hashOf(caller.hashCode(), seed, this.hashCode()))
//
// `Random(seed: Int)` = kotlin.random.XorWowRandom (java.util.Random DEĞİL).
// Üreteç zaten `SeededRandom` olarak var; burada eksik olan üç parça tamamlanıyor:
//   1) Java `String.hashCode()` semantiği (Swift `hashValue` süreç başına rastgele
//      tohumlandığı için ASLA kullanılamaz),
//   2) Unciv `utils/Randomness.kt` içindeki `hashOf` / `withHash`,
//   3) `GameContext.hashCode()` alan alan karşılığı ve ondan türeyen tohum.
//
// Bütün aritmetik Int32 taşmalı (`&*`, `&+`) — Java/Kotlin `Int` ile aynı.
// =====================================================================================

// MARK: - Java hash ilkelleri

/// Java `String.hashCode()`: `s[0]*31^(n-1) + s[1]*31^(n-2) + ... + s[n-1]`, Int32 taşmalı.
/// UTF-16 kod birimleri üzerinden yürür (Java `String` de öyle), bu yüzden `unicodeScalars`
/// değil `utf16` kullanılır — BMP dışı karakterlerde ikisi farklı sonuç verir.
@inline(__always)
func javaStringHash(_ s: String) -> Int32 {
    var h: Int32 = 0
    for u in s.utf16 { h = h &* 31 &+ Int32(u) }
    return h
}

/// Java `Long.hashCode()`: `(int)(value ^ (value >>> 32))`
@inline(__always)
func javaLongHash(_ v: Int64) -> Int32 {
    Int32(truncatingIfNeeded: v ^ Int64(bitPattern: UInt64(bitPattern: v) >> 32))
}

/// Java `Boolean.hashCode()`: true → 1231, false → 1237
@inline(__always)
func javaBoolHash(_ b: Bool) -> Int32 { b ? 1231 : 1237 }

/// The table a `java.util.HashMap` holds `n` entries in once grown from its default 16 slots - doubled while `n`
/// passes three quarters of it - which is also the table `HashSet(Collection)` builds on the reference's JDK 19:
/// `HashMap.newHashMap(max(n, 12))`, tableSizeFor(ceil(n / 0.75)). A set only ever sits in a LARGER table than this
/// when entries left it without the table shrinking (Unciv `withoutItem`: the copy is sized before the removal).
func javaHashTableLength(_ n: Int) -> Int {
    var t = 16
    while n > (t * 3) / 4 { t <<= 1 }
    return t
}

/// `java.util.HashMap` yineleme sırası. Kotlin'in `hashMapOf` haritaları ekleme sırasını
/// DEĞİL kova sırasını gezer, ve `values.random(rng)` / `values.first()` gibi çağrılar bu
/// sıraya göre iş görür; birebir aynı kalmak için sırayı burada yeniden üretiyoruz.
///
/// Kova indeksi `spread(hash) & (kapasite - 1)`, kova içinde ekleme sırası korunur — `resize`
/// bir kovayı ikiye bölerken de göreli sırayı bozmaz, bu yüzden nihai sıra, ekleme dizisinin
/// nihai kova indeksine göre KARARLI sıralanmışıdır. Kapasite 16'da başlar ve eleman sayısı
/// `kapasite * 3 / 4` yük çarpanını aştığında ikiye katlanır.
func javaHashMapOrder(_ keys: [String]) -> [String] {
    var capacity = 16
    while keys.count > capacity * 3 / 4 { capacity <<= 1 }
    let mask = Int32(capacity - 1)
    @inline(__always) func bucket(_ k: String) -> Int32 {
        let h = javaStringHash(k)
        return (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)) & mask
    }
    return keys.enumerated()
        .map { (bucket($0.element), $0.offset, $0.element) }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        .map { $0.2 }
}

/// Java `Float.hashCode()` == `floatToIntBits` — Kotlin `Float.hashCode()` bunu çağırır.
@inline(__always)
func javaFloatHash(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

/// Java `java.time.LocalDate.hashCode()`:
///   `(year & 0xFFFFF800) ^ ((year << 11) + (month << 6) + day)`
/// Unciv `HolidayDates.getHolidayByDate` bu hash'i `Random(...)` tohumu olarak kullanır.
/// Gerçek JDK üzerinde ölçüldü (7 tarihin hepsinde birebir).
@inline(__always)
func javaLocalDateHash(year: Int, month: Int, day: Int) -> Int32 {
    let y = Int32(truncatingIfNeeded: year)
    return (y & Int32(bitPattern: 0xFFFFF800)) ^ ((y << 11) &+ (Int32(truncatingIfNeeded: month) << 6) &+ Int32(truncatingIfNeeded: day))
}

/// Unciv `utils/Randomness.kt`: `fun Int.withHash(hash: Int) = this * 31 + hash`
@inline(__always)
func withHash(_ acc: Int32, _ h: Int32) -> Int32 { acc &* 31 &+ h }

/// Unciv `utils/Randomness.kt`: `fun hashOf(vararg hashes: Int): Int` — 0'dan başlar,
/// her hash'i `withHash` ile katar. `hashOf(a, b, c) == ((a*31)+b)*31+c`.
@inline(__always)
func hashOf(_ hashes: Int32...) -> Int32 { hashOfList(hashes) }

@inline(__always)
func hashOfList(_ hashes: [Int32]) -> Int32 {
    var f: Int32 = 0
    for h in hashes { f = withHash(f, h) }
    return f
}

/// Unciv `Tile.position.hashCode()` karşılığı. Unciv `HexMath.kt:391`:
/// `data class HexCoord(val x: Int = 0, val y: Int = 0)` — `hashCode()` geçersiz kılınmaz,
/// yani Kotlin data class üretimi `x.hashCode() * 31 + y.hashCode()` = `31*x + y`.
/// (Gerçek Unciv.jar üzerinde çalıştırılarak doğrulandı.)
@inline(__always)
func hexHash(_ c: HexCoord) -> Int32 {
    Int32(truncatingIfNeeded: c.q) &* 31 &+ Int32(truncatingIfNeeded: c.r)
}

// MARK: - Unciv'in kendi karo koordinati uzerinden hash'ler

extension GameState {
    /// A fixed order for coordinates that reached us through a `Set`.
    ///
    /// Unciv walks `city.tiles` and friends as Kotlin `HashSet`s - an order fixed by the hashes of what is in
    /// them - and then sorts with the stable `sortedBy`, so two candidates with the same score always come out
    /// the same way round. A Swift `Set` is seeded afresh in every process and `sorted(by:)` is not stable, so
    /// without a tie-break of our own the winner is decided by the run.
    ///
    /// This is a canonical order, not Unciv's, and it costs at most a tie. Use it only where Unciv's own walk
    /// cannot be derived - a `HashSet<Tile>` or `HashMap<Tile, _>`, since `Tile` overrides no `hashCode` and so
    /// buckets by the JVM identity hash. Where the collection is keyed on `HexCoord`, `uncivTileWalk` below
    /// reproduces the real walk instead.
    func uncivTileOrder<S: Sequence>(_ tiles: S) -> [HexCoord] where S.Element == HexCoord {
        tiles.sorted { a, b in
            let p = uncivPosition(a), q = uncivPosition(b)
            return (p.x, p.y) < (q.x, q.y)
        }
    }

    /// The order Unciv walks a city's tiles.
    ///
    /// `City.tiles` there is a Kotlin `HashSet<HexCoord>` and `HexCoord` is a data class, so its hash is
    /// `31 * x + y` over UNCIV's coordinates - a real hash, not the JVM identity hash that makes the tile
    /// purchase unmirrorable. `java.util.HashMap` walks bucket 0..n-1 and keeps insertion order inside a bucket,
    /// and Java 8's resize splits a bin into a low and a high half without reordering either, so the walk is
    /// exactly a STABLE sort of the insertion sequence by the final bucket index.
    ///
    /// The table is the one the set sits in: `tilesTable` when a `withoutItem` copy left it larger than the size
    /// implies (a city down to 12 tiles from 13 keeps 32 slots, see City.tilesWithoutItem), else the one the size
    /// implies. Not modelled, and out of reach of a city: a bin that treeifies (8 entries in one bucket of a table
    /// of 64 or more).
    func uncivTileWalk(_ city: City) -> [HexCoord] {
        var order = city.tilesOrder.filter { city.tiles.contains($0) }
        if order.count != city.tiles.count {   // an old save, or a site that added a tile without the order
            order += city.tiles.subtracting(order).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        }
        return javaHashSetOrder(order, table: city.tilesTable)
    }

    /// The walk of Unciv's City.workedTiles, a HashSet<HexCoord> (see uncivTileWalk): `workedTiles` in the order the
    /// tiles went into the set now held, over the table `workedTilesTable` records.
    func workedTilesWalk(_ city: City) -> [HexCoord] {
        javaHashSetOrder(city.workedTiles, table: city.workedTilesTable)
    }

    /// The walk of Unciv's City.lockedTiles, a HashSet<HexCoord> changed in place (see City.lockedTiles).
    func lockedTilesWalk(_ city: City) -> [HexCoord] {
        var order = city.lockedTilesOrder.filter { city.lockedTiles.contains($0) }
        if order.count != city.lockedTiles.count {   // a save from before the order was kept
            order += city.lockedTiles.subtracting(order).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        }
        return javaHashSetOrder(order, table: city.lockedTilesTable)
    }

    /// A HashSet<HexCoord> filled in `coords` order, over a table of `table` slots when that is larger than the one
    /// its size implies (javaHashTableLength).
    func javaHashSetOrder(_ coords: [HexCoord], table: Int = 0) -> [HexCoord] {
        let n = max(table, javaHashTableLength(coords.count))   // HashMap's default 16, doubled past three quarters
        let mask = Int32(n - 1)
        return coords.enumerated().sorted { a, b in
            let ba = javaBucket(a.element, mask), bb = javaBucket(b.element, mask)
            return ba != bb ? ba < bb : a.offset < b.offset
        }.map { $0.element }
    }

    /// HashMap.hash's spread over Unciv's own tile hash, then the bucket index.
    private func javaBucket(_ c: HexCoord, _ mask: Int32) -> Int32 {
        let h = uncivPositionHash(c)
        return (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)) & mask
    }

    /// Unciv `Tile.position` karsiligi: bizim ofset (col, row) koordinatimizin Unciv
    /// hex uzayindaki (x, y) hali. Donusum `UncivSave.Frame.unciv(col:row:)` — ayni
    /// donusumu `MapGenerator.mirror`, `CityPopulationManager` ve `MapRegions` da kullanir.
    /// Yalnizca harita genisligi/yuksekligine bagli, yani tamamen belirlenimci.
    func uncivPosition(_ c: HexCoord) -> (x: Int, y: Int) {
        UncivSave.Frame.forExport(width: map.width, height: map.height).unciv(col: c.offsetCol, row: c.offsetRow)
    }

    /// Unciv `tile.position.hashCode()`. `HexCoord` bir Kotlin `data class`'i (`HexMath.kt:391`),
    /// yani uretilen hashCode `x.hashCode() * 31 + y.hashCode()` = `31*x + y`, Int32 tasmali.
    /// (Unciv.jar icindeki `com.unciv.logic.map.HexCoord` uzerinde olculdu.)
    func uncivPositionHash(_ c: HexCoord) -> Int32 {
        let p = uncivPosition(c)
        return Int32(truncatingIfNeeded: p.x) &* 31 &+ Int32(truncatingIfNeeded: p.y)
    }

    /// Unciv `tile.position.toVector2().hashCode()`. libGDX `Vector2.hashCode()`:
    ///   `result = 1; result = 31*result + floatToIntBits(x); result = 31*result + floatToIntBits(y)`
    /// yani `961 + 31*bits(x) + bits(y)`, Int32 tasmali — `HexCoord.hashCode()` ile AYNI DEGIL.
    /// (gdx-1.14.2.jar uzerinde olculdu.)
    func uncivPositionVector2Hash(_ c: HexCoord) -> Int32 {
        let p = uncivPosition(c)
        return 961 &+ 31 &* javaFloatHash(Float(p.x)) &+ javaFloatHash(Float(p.y))
    }
}

// MARK: - Harita üretimi bağlamı: `GameContext(tile = tile)` (gameInfo YOK)

/// Unciv `GameContext` yapıcısında `gameInfo` varsayılanı `tile`'dan **türetilmez**
/// (`GameContext.kt:32-33`: "tile and region do not deduce gameInfo because that field is not set
/// during MapGeneration"). `TileMap.gameInfo` zaten `lateinit`, harita üretimi sırasında atanmamış.
/// Bu yüzden `GameContext(tile = tile).hashCode()` içinde dolu olan TEK alan
/// `relevantTile.position.hashCode()` = `31 * x + y` olur (`HexCoord` bir data class):
///
///   hashOf(0, 0, 0, 0, 0, 31*x + y, 0, 0, 0, 0, 0, 0, false.hashCode() /* 1237 */)
///
/// Yani harita tohumu (`mapParameters.seed`) bu akışa **hiç girmez** — Unciv'de de girmiyor;
/// aynı karo konumu her haritada aynı akışı verir. Bu bir varsayım değil: gerçek `Unciv.jar`
/// içinde `GameContext(tile = Tile(position = HexCoord(x, y)))` kurulup `hashCode()` ve
/// `stateBasedRandom(...)` çıktıları bu koda karşı ölçüldü.
@inline(__always)
func uncivMapGenTileContextHash(x: Int, y: Int) -> Int32 {
    hashOf(0, 0, 0, 0, 0,
           Int32(truncatingIfNeeded: x) &* 31 &+ Int32(truncatingIfNeeded: y),
           0, 0, 0, 0, 0, 0,
           javaBoolHash(false))
}

/// Unciv `GameContext(tile = tile).stateBasedRandom(caller)` — harita üretimindeki karo akışı.
/// `caller` dizeleri Unciv kaynağından birebir alınmalıdır (hash'e giriyorlar).
/// `x`/`y` Unciv'in kendi karo konumudur; bizim (sütun, satır) ızgaramızdan
/// `UncivSave.Frame.forExport(...).unciv(col:row:)` ile elde edilir.
func mapGenTileRandom(_ caller: String, x: Int, y: Int, seed: Int32 = 31) -> SeededRandom {
    SeededRandom(kotlinSeed: hashOf(javaStringHash(caller), seed, uncivMapGenTileContextHash(x: x, y: y)))
}

// MARK: - Harita üretimi bağlamı: `GameContext(gameInfo = tileMap.gameInfo[, region])`

/// Unciv `GameContext.hashCode()`'un 1. alanı:
///   `gameInfo?.gameId?.hashCode() ?: gameInfo?.tileMap?.mapParameters?.seed?.hashCode() ?: 0`
///
/// ÖLÇÜM (gerçek `Unciv.jar`):
///   * `GameInfo.gameId` `randomGameId()` ile **dolu** başlar (`GameInfo.kt:117`) — 36 karakterlik
///     rastgele UUID; `GameStarter` `GameInfo()`yi haritadan önce kurar (`GameStarter.kt:47`) ve
///     `MapGenerator.generateMap` `map.gameInfo = gameInfo` atamasını bölge aşamasından hemen önce
///     yapar (`MapGenerator.kt:210`). Yani bu bağlamlarda `gameInfo` doludur ve `turns == 0`'dır.
///   * `gameId` Kotlin'de **nullable olmayan** `String`; `?.hashCode()` asla null dönmez, bu yüzden
///     `?:` zinciri ikinci dala hiç geçmez — `mapParameters.seed` dalı Unciv'de **ölü kod**.
///     (Ölçüldü: `gameId = ""` iken bile hash `"".hashCode() = 0` dalını verir, tohum dalını değil.)
///   * Sonuç: Unciv'de bu akışlar **her oyunda rastgele** (`GameStarter.kt:33`'teki yorum da bunu
///     söylüyor: "random ... based on the gameId, which is fully random per game").
///
/// Epochs tekrarlanabilir olmak zorunda (regresyon kapısı: 25 tur birebir aynı). Bu yüzden
/// `GameState.contextHash`'in 1. alanıyla **birebir aynı ifade** kullanılır: çevrimiçi oyunda dolu
/// olan `settings.gameId`, yoksa harita tohumu. İkisi de kayıtta durur, süreçten süreçe değişmez.
func uncivMapGenGameHash(gameId: String?, seed: UInt64) -> Int32 {
    gameId.map(javaStringHash) ?? javaLongHash(Int64(bitPattern: seed))
}

/// libGDX `Rectangle.hashCode()` — Unciv `GameContext.hashCode()` içindeki
/// `fun Region?.hash() = this?.rect?.hashCode() ?: 0` tam olarak bunu çağırır.
/// Alan sırası **height, width, x, y** ve `result = 1` kabuğu:
///   `((((1*31 + bits(h))*31 + bits(w))*31 + bits(x))*31 + bits(y))`
/// `floatToRawIntBits` üzerinden, Int32 taşmalı. (gdx-1.14.2 sınıfı üzerinde ölçüldü —
/// `Rect(0,0,0,0) -> 923521`, `Rect(3,5,20,7) -> -181528703`.)
/// Bizim `Rect` alanları `Double`; Unciv `Float` tutar, bu yüzden hash'ten önce `Float`'a indirilir.
func gdxRectangleHash(x: Double, y: Double, width: Double, height: Double) -> Int32 {
    var r: Int32 = 1
    r = r &* 31 &+ javaFloatHash(Float(height))
    r = r &* 31 &+ javaFloatHash(Float(width))
    r = r &* 31 &+ javaFloatHash(Float(x))
    r = r &* 31 &+ javaFloatHash(Float(y))
    return r
}

/// `GameContext(gameInfo = tileMap.gameInfo[, region = region]).hashCode()`.
/// 13 alanın yalnızca ikisi dolu: 1. alan `gameHash`, 11. alan `region.rect.hashCode()`.
/// (`turns == 0`, `civInfo`/`city`/`unit`/`tile`/savaşçılar hepsi null, `ignoreConditionals == false`.)
/// Gerçek `Unciv.jar` üzerinde ölçüldü: `gameId = "FIXED-GAME-ID"` için 886565208, bölgeli
/// beş dikdörtgen için de tahminle birebir.
@inline(__always)
func uncivMapGenGameContextHash(gameHash: Int32, regionRectHash: Int32 = 0) -> Int32 {
    hashOf(0, gameHash, 0, 0, 0, 0, 0, 0, 0, 0, 0, regionRectHash, javaBoolHash(false))
}

/// `GameContext(gameInfo = ...).stateBasedRandom(caller)` — harita üretimindeki "oyun geneli" akış.
func mapGenGameRandom(_ caller: String, gameHash: Int32, regionRectHash: Int32 = 0, seed: Int32 = 31) -> SeededRandom {
    SeededRandom(kotlinSeed: hashOf(javaStringHash(caller), seed,
                                    uncivMapGenGameContextHash(gameHash: gameHash, regionRectHash: regionRectHash)))
}

/// `civ.state.stateBasedRandom(caller)` — harita üretimi sırasında.
/// `Civilization.state` `@Transient var state = GameContext.EmptyState` olarak başlar
/// (`Civilization.kt:89`) ve yalnızca `CivInfoTransientCache.updateState()` ile değişir; o da
/// `GameInfo.setTransients()` içinden çağrılır (`GameInfo.kt:758-760`), yani haritadan **sonra**
/// (`GameStarter.kt:122`). Dolayısıyla harita üretiminde bağlam hash'i `EmptyState`'inkidir:
/// `hashOf(0×12, false.hashCode()) == 1237` (Unciv.jar'da ölçüldü).
/// Bunun doğrudan sonucu: **her civ aynı tohumu alır**. Unciv'de de böyle; birebir kopyalandı.
func mapGenCivStateRandom(_ caller: String, seed: Int32 = 31) -> SeededRandom {
    SeededRandom(kotlinSeed: hashOf(javaStringHash(caller), seed,
                                    hashOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, javaBoolHash(false))))
}

// MARK: - SeededRandom üzerine Kotlin uyumlu kısayollar

extension SeededRandom {
    /// Kotlin `Random.nextInt(until)` — Int sarmalayıcı (mevcut `nextInt(until: Int32)` ile
    /// karışmaması için ayrı etiket).
    mutating func nextInt(below until: Int) -> Int {
        until <= 0 ? 0 : Int(nextInt(until: Int32(clamping: until)))
    }

    /// Unciv'in `<with []% chance>` ve intercept kontrolleri `nextFloat()` kullanır,
    /// `nextDouble()` değil — iki akış aynı tohumdan farklı sayılar üretir.
    mutating func chanceFloat(_ p: Double) -> Bool { Double(nextFloat()) < p }

    /// Kotlin `Collection<T>.random(rng)` = `elementAt(rng.nextInt(size))`.
    mutating func randomElement<T>(_ a: [T]) -> T? { pick(a) }
}

// MARK: - GameContext.hashCode() ve stateBasedRandom

extension GameState {

    // -- Unciv GameContext'in `relevant*` lazy alanları ------------------------------

    /// Unciv `GameContext.relevantCity`: açık şehir, yoksa `tile` (attackedTile DEĞİL) ya da
    /// birimin karosunun sahibi şehir — ve yalnızca bizim (ya da birimin) civ'imize aitse.
    func relevantCity(_ ctx: UniqueContext) -> City? {
        if let c = ctx.city { return c }
        guard let coord = ctx.tile?.coord ?? ctx.unit?.coord, let c = owningCity(coord) else { return nil }
        if c.civId == ctx.civId || c.civId == ctx.unit?.civId { return c }
        return nil
    }

    // -- Unciv GameContext.hashCode() iç hash'leri ----------------------------------

    /// Unciv `fun MapUnit?.hash()`:
    /// `name.hashCode() + (if (hasTile()) 17 * currentTile.hash() else 0) + (17 * currentMovement).hashCode()`
    /// `currentMovement` Kotlin'de Float'tır; bu yüzden çarpım da Float aritmetiğiyle yapılır.
    func unitHash(_ u: Unit?) -> Int32 {
        guard let u else { return 0 }
        return javaStringHash(u.name)
            &+ 17 &* uncivPositionHash(u.coord)
            &+ javaFloatHash(17 * Float(u.movementLeft))
    }

    /// Unciv `fun ICombatant?.hash()`: birim savaşçısı birimin hash'ini verir,
    /// şehir savaşçısı `getName().hashCode() + 17 * getTile().hash()`.
    func cityCombatantHash(_ c: City?) -> Int32 {
        guard let c else { return 0 }
        return javaStringHash(c.name) &+ 17 &* uncivPositionHash(c.coord)
    }

    /// Unciv `GameContext.hashCode()` — alan sırası birebir korunur, çünkü `hashOf` sıraya duyarlı.
    ///
    /// Unciv alanı                         → Epochs karşılığı
    ///   gameInfo.turns                    → `turn - 1` (Unciv sayacı 0 tabanlı)
    ///   gameId ?: mapParameters.seed      → `settings.gameId` ?: `settings.seed`
    ///   relevantCiv.civID.hashCode()      → `ctx.civId` (bizde Int, Unciv'de UUID string)
    ///   relevantCity.id.hashCode()        → `relevantCity(ctx)?.id`
    ///   relevantUnit.hash()               → `unitHash(ctx.unit)`
    ///   relevantTile.position.hashCode()  → `uncivPositionHash(relevantTile(ctx))` - Unciv hashes ITS OWN
///   (x, y), not our (q, r); hashing ours gave every tile-bearing context a different seed.
    ///   ourCombatant.hash()               → savaş bağlamında kendi birimimiz / şehrimiz
    ///   theirCombatant.hash()             → `ctx.opponentUnit` ya da rakip şehir
    ///   attackedTile.position.hashCode()  → `hexHash(ctx.attackedTile)`
    ///   combatAction.name.hashCode()      → `ctx.combatAction` ("Attack"/"Defend"/"Intercept")
    ///   otherCiv.civID.hashCode()         → `ctx.opponentCivId`
    ///   region.rect.hashCode()            → bizde bölge nesnesi yok → 0
    ///   ignoreConditionals.hashCode()     → bizde yok → `false` → 1237
    func contextHash(_ ctx: UniqueContext) -> Int32 {
        // ourCombatant: only a combat context has one - our unit, or our city when a city is the one fighting
        let ourCombatant: Int32 = !ctx.isCombat ? 0
            : (ctx.unit != nil ? unitHash(ctx.unit) : cityCombatantHash(ctx.city))
        // theirCombatant: the other unit, or the other city (CityCombatant: name + 17 * tile)
        let theirCity: City? = ctx.opponentCity
            ?? (ctx.opponentIsCity && ctx.opponentUnit == nil && ctx.resolvedCombatAction != "Defend" ? ctx.attackedTile.flatMap { city(at: $0.coord) } : nil)
        let theirCombatant: Int32 = ctx.opponentUnit != nil ? unitHash(ctx.opponentUnit) : cityCombatantHash(theirCity)

        return hashOf(
            Int32(truncatingIfNeeded: uncivTurns),
            settings.gameId.map(javaStringHash) ?? javaLongHash(Int64(bitPattern: settings.seed)),
            // Unciv hashes `civInfo.civID` and `city.id`, which are STRINGS - the civ's name and the city's UUID.
            // Our integer ids are indices into our own arrays and mean nothing to Unciv, so hashing them gave a
            // different seed for every roll that involves a civ or a city, which is most of them.
            civ(ctx.civId).map { javaStringHash($0.nation) } ?? 0,
            relevantCity(ctx).map { javaStringHash($0.uncivId) } ?? 0,
            unitHash(ctx.unit),
            relevantTile(ctx).map { uncivPositionHash($0.coord) } ?? 0,
            ourCombatant,
            theirCombatant,
            ctx.attackedTile.map { uncivPositionHash($0.coord) } ?? 0,
            ctx.resolvedCombatAction.map(javaStringHash) ?? 0,
            // Same as relevantCiv above: Unciv hashes `otherCiv.civID`, the nation's NAME. Hashing our integer id
            // here meant every roll with an opponent - every melee exchange, every diplomacy chance - drew from a
            // different stream. It survived because the exchange only shows when one side dies partway through it.
            ctx.opponentCivId.flatMap { civ($0) }.map { javaStringHash($0.nation) } ?? 0,
            0,                      // Unciv region.rect.hashCode() — bizde harita bölgesi nesnesi yok
            javaBoolHash(false)     // Unciv ignoreConditionals.hashCode()
        )
    }

    // -- Asıl API -------------------------------------------------------------------

    /// Unciv `GameContext.stateBasedRandom(caller, seed = 31)`.
    /// Aynı tur + aynı durum + aynı çağıran → aynı akış; yeniden yükleyip tekrar denemek
    /// (save scumming) sonucu değiştirmez.
    func stateBasedRandom(_ caller: String, _ ctx: UniqueContext, seed: Int32 = 31) -> SeededRandom {
        SeededRandom(kotlinSeed: hashOf(javaStringHash(caller), seed, contextHash(ctx)))
    }

    /// Unciv `City.pseudoRandomId(civ)`:
    /// `pseudoRandomUuid(GameContext(civ).stateBasedRandom("City.Id", civ.cities.size)).toString()`.
    ///
    /// A city founded during play is not in the save, so it has no id from there - and Unciv hashes `city.id`,
    /// a UUID string, into the context of every roll made in or about that city. Ours left the field empty, so
    /// the hash was 0 and every such roll drew from a different stream than Unciv's: the melee exchange of a
    /// unit attacking out of a city it founded, most visibly. The UUID is not random, it is drawn from the
    /// civ's own state-based random, so it can be reproduced exactly.
    func pseudoRandomCityId(civId: Int) -> String {
        var rng = stateBasedRandom("City.Id", civId: civId, seed: Int32(cities(of: civId).count))
        let most = (rng.nextLong() & ~0xf000) | 0x4000
        let least = (rng.nextLong() & 0x3fff_ffff_ffff_ffff) | Int64(bitPattern: UInt64(1) << 63)
        return javaUUIDString(most: most, least: least)
    }

    /// Java `UUID.toString()`: 8-4-4-4-12 lower-case hex digits taken from the two longs.
    private func javaUUIDString(most: Int64, least: Int64) -> String {
        func digits(_ value: Int64, _ count: Int) -> String {
            let hi = UInt64(1) << UInt64(count * 4)
            let v = hi | (UInt64(bitPattern: value) & (hi - 1))
            return String(String(v, radix: 16).dropFirst())
        }
        return digits(most >> 32, 8) + "-" + digits(most >> 16, 4) + "-" + digits(most, 4) + "-"
            + digits(least >> 48, 4) + "-" + digits(least, 12)
    }

    /// `civInfo.state.stateBasedRandom(...)` karşılığı.
    func stateBasedRandom(_ caller: String, civId: Int, seed: Int32 = 31) -> SeededRandom {
        stateBasedRandom(caller, UniqueContext(civId: civId), seed: seed)
    }

    /// Unciv `GameContext(civ, civ2)` (GameContext.kt:42) ve `DiplomacyManager.state`
    /// (DiplomacyManager.kt:198-201 → `GameContext(civInfo, otherCiv)`) karşılığı.
    /// `otherCiv` `hashOf`'un 11. alanıdır; savaşçı/karo alanları boş kalır.
    func stateBasedRandom(_ caller: String, civId: Int, otherCivId: Int?, seed: Int32 = 31) -> SeededRandom {
        stateBasedRandom(caller, UniqueContext(civId: civId, opponentCivId: otherCivId), seed: seed)
    }

    /// Unciv `UniqueTriggerActivation.getTriggerFunction` (UniqueTriggerActivation.kt:113-115):
    ///   `val tileBasedRandom = if (tile != null) Random(tile.position.hashCode()) else Random(-550)`
    /// `Random(Int)` yolu; hash `HexCoord.hashCode()` = `31*x + y` (Unciv.jar üzerinde ölçüldü),
    /// `toVector2()` kabuğu YOK.
    func triggerTileRandom(_ coord: HexCoord?) -> SeededRandom {
        SeededRandom(kotlinSeed: coord.map { uncivPositionHash($0) } ?? -550)
    }

    /// `city.state.stateBasedRandom(...)` karşılığı — Unciv `GameContext(city)` yapıcısı
    /// civ'i, şehri ve şehir merkezini birlikte doldurur.
    func stateBasedRandom(_ caller: String, city c: City, seed: Int32 = 31) -> SeededRandom {
        stateBasedRandom(caller, UniqueContext(civId: c.civId, city: c, tile: map[c.coord]), seed: seed)
    }

    /// `unit.cache.state.stateBasedRandom(...)` karşılığı — Unciv `GameContext(unit)`.
    func stateBasedRandom(_ caller: String, unit u: Unit, seed: Int32 = 31) -> SeededRandom {
        stateBasedRandom(caller, UniqueContext(civId: u.civId, unit: u, tile: map[u.coord]), seed: seed)
    }

    /// `tile.stateThisTile.stateBasedRandom(...)` karşılığı.
    func stateBasedRandom(_ caller: String, tile t: Tile, seed: Int32 = 31) -> SeededRandom {
        stateBasedRandom(caller, UniqueContext(civId: t.ownerCivId ?? -1, tile: t), seed: seed)
    }

    /// Unciv `GameContext(ourCombatant, theirCombatant, attackedTile, combatAction)` yapıcısı.
    /// `action`: "Attack" | "Defend" | "Intercept" (Unciv `CombatAction` enum adları).
    func battleContext(our: Unit, their: Unit?, theirCity: City? = nil,
                       attackedTile: HexCoord?, action: String) -> UniqueContext {
        UniqueContext(
            civId: our.civId,
            unit: our,
            tile: map[our.coord],
            attackedTile: attackedTile.flatMap { map[$0] },
            attacking: action == "Attack",
            opponentUnit: their,
            opponentIsCity: theirCity != nil,
            opponentCivId: their?.civId ?? theirCity?.civId,
            combatAction: action,
            opponentCity: theirCity
        )
    }

    /// Unciv `Conditionals.getStateBasedRandom(state, unique)`:
    ///   `Random(hashOf(gameInfo.turns, unique.hashCode(), state.hashCode())).nextFloat()`
    /// Unciv'de `Unique` hashCode'u geçersiz kılmaz, yani JVM kimlik hash'i kullanılır ve
    /// değer süreçler arasında değişir. Referans `-XX:hashCode=2` ile koştuğu için bu hash 1'dir.
    func conditionalChanceRoll(_ uniqueText: String, _ ctx: UniqueContext, hasUnique: Bool = true) -> Float {
        var rng = SeededRandom(kotlinSeed: hashOf(
            Int32(truncatingIfNeeded: uncivTurns),
            hasUnique ? 1 : 0,   // unique?.hashCode() ?: 0 - Unique overrides none, and the reference runs with every identity hash = 1
            contextHash(ctx)
        ))
        let r = rng.nextFloat()
        if ProcessInfo.processInfo.environment["CHANCEDBG"] != nil {
            func p(_ c: HexCoord?) -> String { c.map { let q = uncivPosition($0); return "\(q.x),\(q.y)" } ?? "nil" }
            print("CHANCEE t=\(uncivTurns) [\(uniqueText)] civ=\(civ(ctx.civId)?.nation ?? "nil") city=\(relevantCity(ctx)?.name ?? "nil") unit=\(ctx.unit?.name ?? "nil")@\(p(ctx.unit?.coord)):mv\(ctx.unit.map { Float($0.movementLeft) }.map { "\($0)" } ?? "nil") tile=\(p(relevantTile(ctx)?.coord)) their=\(ctx.opponentUnit?.name ?? ctx.opponentCity?.name ?? "nil")@\(p(ctx.opponentUnit?.coord ?? ctx.opponentCity?.coord)):mv\(ctx.opponentUnit.map { "\(Float($0.movementLeft))" } ?? "nil") atk=\(p(ctx.attackedTile?.coord)) act=\(ctx.resolvedCombatAction ?? "nil") other=\(ctx.opponentCivId.flatMap { civ($0)?.nation } ?? "nil") sh=\(contextHash(ctx)) r=\(r)")
        }
        return r
    }
}
