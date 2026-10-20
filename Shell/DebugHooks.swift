// Shell for the Unciv 4X core (MPL-2.0): stand-ins for the developer's test and measurement tooling, which the published
// core leaves out. Every switch here is off; the hooks only have to exist and type-check, never to log.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import CoreGraphics

// MARK: debug switches read by game logic (all off in this build)
var epochsDebug = false
var epochsAutoplay = false
var epochsTraceUnit: String? = nil
var epochsRankCity: String? = nil
var epochsTradeDbg = false
var epochsBtlDbg = false
var epochsVerifyStats = false
var epochsWanderDbg = false
var epochsNoTileBuy = false
var epochsNoShuffle = false

// MARK: event log (EVLOG) - the developer's turn-by-turn diff harness against Unciv's JVM build
enum EvLog {
    static var on = false
    static var notif = false
    static var muted = false
    static var probing = false
    static var game: GameState? = nil
    static var pendingInstantTradeEnds: [String: [String]] = [:]
    static var pendingPeaceTradeEnds: [String: [String]] = [:]
    static var pendingSeq: [String: [Int]] = [:]
    static var tradeSeq: [String: Int] = [:]
    static var importedTrades: [(Int, Int, Int, Int, String, Int)] = []

    static func name(_ s: String) -> String { s }
    static func f1(_ d: Double) -> String { String(format: "%.1f", d) }
    static func flushProduction() {}
    static func tileOwner<C, T>(_ c: C, city: T, owned: Bool) {}
    static func tileWrite<T>(old: T, new: T) {}
    static func productionStep<C, P>(_ city: C, _ next: P?) {}
    static func productionSet<C>(_ city: C) {}
    static func gold<N>(_ nation: N, _ old: Double, _ new: Double) {}
}

extension GameState {
    static var evlogOn: Bool { EvLog.on }
}

func ev<C>(_ civ: C, _ fields: String...) {}
func evPos<P>(_ p: P) -> String { "\(p)" }
func evOtherName<C>(_ civ: C) -> String { "\(civ)" }
func evUnitMove<I, P>(_ unitId: I, from: P) {}
func evUnitAdd<U>(_ unit: U) {}
func evUnitDie<U>(_ unit: U) {}
func evResources<C, R>(_ civ: C, old: R) {}
func evTradeStart<O>(_ offer: O, tradeId: Int) {}
func evPeaceTreatyStart<A, B>(_ a: A, _ b: B) {}
func evTradeEndsInStartOrder<A, B>(_ a: A, _ b: B) {}
@discardableResult func evTradeEnd<A, B, G>(_ a: A, _ b: B, _ group: G) -> String? { nil }

// MARK: input trace (off)
enum InputTrace {
    static var on = false
    static func log(_ s: @autoclosure () -> String) {}
    static func hex<H>(_ h: H) -> String { "\(h)" }
    static func pt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}

/// Touch tracing recognizer: never added in this build (InputTrace.on is false), a plain recognizer that recognizes nothing.
final class TouchTraceRecognizer: UIGestureRecognizer {}

// MARK: state dump / self test (off)
enum StateDump {
    static var captureTrees = false
    static var trees: [Int: (StatTreeNode, StatTreeNode)] = [:]
}

enum CityScreenSelfTest {
    struct Request { var dump = false }
    static var request: Request? = nil
    static var selectConstruction: ((Production?) -> Void)? = nil
}
