// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The thread a turn is played on away from the world screen's Next Turn - the multiplayer screen's Resign and Skip
/// turn, which Unciv runs with `Concurrency.runOnNonDaemonThreadPool("Resign")` / `("Skip turn")`
/// (MultiplayerScreen.kt:208,253), a thread of a cached pool made for the job (Concurrency.kt:189-198).
/// Ours is a thread of its own with the NextTurn thread's 8 MB stack (GameController.endTurn): an async function goes
/// on after an `await` on a thread of Swift's concurrency pool, whose 512 KB stack the 30 September stack overflow's
/// walk outgrew (automateUnitMoves → foundCity → addBuilding → triggerUniques on a 512 KB queue, its build configuration
/// not recorded). In Release a whole turn on six sampled saves took under 256 KB,
/// so the 8 MB is the NextTurn thread's margin, not a measured need.
enum TurnThread {
    static let stackSize = 8 << 20

    private final class Box<T>: @unchecked Sendable { var value: T?; init(_ value: T? = nil) { self.value = value } }

    private static func start(_ name: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// `body` played on its own thread, the caller suspended until it is done. What `body` touches must be nobody
    /// else's meanwhile - a game just downloaded, with the shared ruleset it activated.
    static func run<T>(_ name: String, _ body: @escaping () -> T) async -> T {
        let job = Box<() -> T>(body)
        let result: Box<T> = await withCheckedContinuation { (done: CheckedContinuation<Box<T>, Never>) in
            start(name) { done.resume(returning: Box(job.value!())) }
        }
        return result.value!
    }

    /// The same thread, waited for on the calling one (the self-tests run on the main thread, which nothing in a turn
    /// waits on).
    static func runAndWait<T>(_ name: String, _ body: @escaping () -> T) -> T {
        let result = Box<T>()
        let finished = DispatchSemaphore(value: 0)
        start(name) { result.value = body(); finished.signal() }
        finished.wait()
        return result.value!
    }
}
