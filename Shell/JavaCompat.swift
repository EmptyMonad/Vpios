// Shell for the Unciv 4X core (MPL-2.0): JVM-order primitives the core calls but the published source leaves out.
// Both are transliterated from a Python model checked against a real JVM (OpenJDK 21) in this repo's ci/jvmcheck:
//  - JavaHash1Set: 1269/1269 HashSet iteration orders, 9 initial capacities x 0...140 elements, plus 141/141 for
//    HashSet(collection) with jdk19CollectionCapacity, plus 977/977 orders after remove() and cleared-table refills
//  - kotlinSortedWith: 264/264 sorts with the identical comparator-call sequence and result (n up to 2048)
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - JavaHash1Set

/// The order java.util.HashSet walks its elements when every element hashes to 1 and identity ties all break the same
/// way (Unciv's reference runs the JVM with -XX:hashCode=2): one bucket; a linked list in insertion order until the
/// ninth entry, which first grows the table to 64 and then turns the bucket into a red-black tree whose `next` chain -
/// rotated by moveRootToFront and by each insert going in after its tree parent - is the iteration order. Removal is
/// HashMap.removeNode / TreeNode.removeTreeNode with balanceDeletion (and untreeify when the tree gets too small).
enum JavaHash1Set {
    /// Kotlin `toHashSet()` / `HashSet(mapCapacity(n))`
    static func kotlinCollectionCapacity(_ n: Int) -> Int {
        if n < 0 { return n }
        if n < 3 { return n + 1 }
        if n < (1 << 30) { return Int(Float(n) / 0.75 + 1.0) }
        return Int(Int32.max)
    }

    /// JDK 19+ `HashSet(Collection)`: `HashMap.newHashMap(max(size, 12))`, i.e. ceil(max(n, 12) / 0.75)
    static func jdk19CollectionCapacity(_ n: Int) -> Int {
        Int((Double(max(n, 12)) / 0.75).rounded(.up))
    }

    /// `initialCapacity` nil: `HashSet()` (16). Otherwise `HashSet(initialCapacity)` - also a set cleared and refilled,
    /// with its old table length. `removing`: then `remove(element)`.
    static func iterationOrder<S: Sequence>(_ inserts: S, initialCapacity: Int? = nil, removing: S.Element? = nil) -> [S.Element] where S.Element: Hashable {
        let b = Bin<S.Element>(initialCapacity: initialCapacity)
        for k in inserts { b.put(k) }
        if let r = removing { b.remove(r) }
        return b.keys()
    }

    /// The walk, and the table length afterwards (0 while no table was allocated): Unciv clears and refills a region's
    /// tile set, which keeps its table.
    static func iterationOrderAndTableLength<S: Sequence>(_ inserts: S, initialCapacity: Int? = nil) -> (order: [S.Element], tableLength: Int) where S.Element: Hashable {
        let b = Bin<S.Element>(initialCapacity: initialCapacity)
        for k in inserts { b.put(k) }
        return (b.keys(), b.cap)
    }

    private final class Node<K> {
        let key: K
        var next: Node?
        weak var prev: Node?
        weak var parent: Node?
        var left: Node?
        var right: Node?
        var red = false
        init(_ key: K, next: Node? = nil) { self.key = key; self.next = next }
    }

    private final class Bin<K: Hashable> {
        typealias N = Node<K>
        var first: N? = nil
        var isTree = false
        var seen = Set<K>()
        var size = 0
        var cap = 0
        var thr: Int
        var usesDefault: Bool

        init(initialCapacity: Int?) {
            usesDefault = initialCapacity == nil
            if let c = initialCapacity { var t = 1; while t < max(c, 0) { t <<= 1 }; thr = t } else { thr = 16 }
        }

        func resize() {
            let newCap: Int, newThr: Int
            if cap > 0 {
                newCap = cap << 1
                newThr = cap >= 16 ? thr << 1 : Int(Float(newCap) * 0.75)
            } else if thr > 0 && !usesDefault {
                newCap = thr; newThr = Int(Float(newCap) * 0.75)
            } else {
                newCap = 16; newThr = 12
            }
            usesDefault = false
            cap = newCap; thr = newThr      // every key sits in the one bucket; a split keeps its order (and its tree)
        }

        func rotateLeft(_ rootIn: N?, _ p: N?) -> N? {
            var root = rootIn
            if let p, let r = p.right {
                p.right = r.left
                if let rl = p.right { rl.parent = p }
                r.parent = p.parent
                if let pp = r.parent {
                    if pp.left === p { pp.left = r } else { pp.right = r }
                } else { root = r; r.red = false }
                r.left = p; p.parent = r
            }
            return root
        }
        func rotateRight(_ rootIn: N?, _ p: N?) -> N? {
            var root = rootIn
            if let p, let l = p.left {
                p.left = l.right
                if let lr = p.left { lr.parent = p }
                l.parent = p.parent
                if let pp = l.parent {
                    if pp.right === p { pp.right = l } else { pp.left = l }
                } else { root = l; l.red = false }
                l.right = p; p.parent = l
            }
            return root
        }
        func balanceInsertion(_ rootIn: N?, _ xIn: N) -> N? {
            var root = rootIn
            var x: N = xIn
            x.red = true
            while true {
                guard var xp = x.parent else { x.red = false; return x }
                guard xp.red, var xpp = xp.parent else { return root }
                if xp === xpp.left {
                    if let xppr = xpp.right, xppr.red {
                        xppr.red = false; xp.red = false; xpp.red = true; x = xpp
                    } else {
                        if x === xp.right {
                            x = xp; root = rotateLeft(root, x)
                            guard let nxp = x.parent else { continue }
                            xp = nxp
                            guard let nxpp = xp.parent else { xp.red = false; continue }
                            xpp = nxpp
                        }
                        xp.red = false
                        xpp.red = true; root = rotateRight(root, xpp)
                    }
                } else {
                    if let xppl = xpp.left, xppl.red {
                        xppl.red = false; xp.red = false; xpp.red = true; x = xpp
                    } else {
                        if x === xp.left {
                            x = xp; root = rotateRight(root, x)
                            guard let nxp = x.parent else { continue }
                            xp = nxp
                            guard let nxpp = xp.parent else { xp.red = false; continue }
                            xpp = nxpp
                        }
                        xp.red = false
                        xpp.red = true; root = rotateLeft(root, xpp)
                    }
                }
            }
        }
        func balanceDeletion(_ rootIn: N?, _ xIn: N?) -> N? {
            var root = rootIn
            var x = xIn
            while true {
                guard let cx = x, cx !== root else { return root }
                guard var xp = cx.parent else { cx.red = false; return cx }
                if cx.red { cx.red = false; return root }
                if xp.left === cx {
                    var xpr = xp.right
                    if let r = xpr, r.red {
                        r.red = false; xp.red = true; root = rotateLeft(root, xp)
                        if let np = cx.parent { xp = np; xpr = np.right } else { xpr = nil }
                    }
                    guard let w = xpr else { x = cx.parent; continue }
                    let sl = w.left, sr = w.right
                    if (sr == nil || !sr!.red) && (sl == nil || !sl!.red) {
                        w.red = true; x = cx.parent
                    } else {
                        var wv: N? = w
                        var xpv: N? = cx.parent
                        if sr == nil || !sr!.red {
                            sl?.red = false
                            w.red = true; root = rotateRight(root, w)
                            xpv = cx.parent; wv = xpv?.right
                        }
                        if let w2 = wv {
                            w2.red = xpv?.red ?? false
                            w2.right?.red = false
                        }
                        if let p2 = xpv { p2.red = false; root = rotateLeft(root, p2) }
                        x = root
                    }
                } else {
                    var xpl = xp.left
                    if let l = xpl, l.red {
                        l.red = false; xp.red = true; root = rotateRight(root, xp)
                        if let np = cx.parent { xp = np; xpl = np.left } else { xpl = nil }
                    }
                    guard let w = xpl else { x = cx.parent; continue }
                    let sl = w.left, sr = w.right
                    if (sl == nil || !sl!.red) && (sr == nil || !sr!.red) {
                        w.red = true; x = cx.parent
                    } else {
                        var wv: N? = w
                        var xpv: N? = cx.parent
                        if sl == nil || !sl!.red {
                            sr?.red = false
                            w.red = true; root = rotateLeft(root, w)
                            xpv = cx.parent; wv = xpv?.left
                        }
                        if let w2 = wv {
                            w2.red = xpv?.red ?? false
                            w2.left?.red = false
                        }
                        if let p2 = xpv { p2.red = false; root = rotateRight(root, p2) }
                        x = root
                    }
                }
            }
        }
        func moveRootToFront(_ root: N) {
            if root !== first {
                let rn = root.next, rp = root.prev
                rn?.prev = rp
                rp?.next = rn
                first?.prev = root
                root.next = first; root.prev = nil
                first = root
            }
        }
        func treeRoot() -> N {
            var r = first!
            while let p = r.parent { r = p }
            return r
        }
        func treeify() {
            var root: N? = nil
            var x = first
            while let cur = x {
                let nxt = cur.next
                cur.left = nil; cur.right = nil
                if let rt = root {
                    var p: N? = rt
                    while true {
                        let xp = p!
                        p = xp.left                     // tieBreakOrder is -1 for every pair: always left
                        if p == nil { cur.parent = xp; xp.left = cur; root = balanceInsertion(root, cur); break }
                    }
                } else { cur.parent = nil; cur.red = false; root = cur }
                x = nxt
            }
            if let root { moveRootToFront(root) }
            isTree = true
        }
        func untreeify() {
            let ks = keys()
            first = nil; isTree = false
            var prev: N? = nil
            for k in ks {
                let n = N(k)
                if let p = prev { p.next = n; n.prev = p } else { first = n }
                prev = n
            }
        }
        func putTree(_ k: K) {
            let root = treeRoot()
            var p: N? = root
            while true {
                let xp = p!
                p = xp.left
                if p == nil {
                    let xpn = xp.next
                    let x = N(k, next: xpn)
                    xp.left = x; xp.next = x; x.parent = xp; x.prev = xp
                    xpn?.prev = x
                    if let r = balanceInsertion(root, x) { moveRootToFront(r) }
                    return
                }
            }
        }
        func put(_ k: K) {
            if seen.contains(k) { return }
            if cap == 0 { resize() }
            if first == nil {
                first = N(k)
            } else if isTree {
                putTree(k)
            } else {
                var e = first!; var count = 1
                while let n = e.next { e = n; count += 1 }
                let n = N(k); e.next = n; n.prev = e
                if count >= 8 {            // binCount >= TREEIFY_THRESHOLD - 1: the ninth entry in the bucket
                    if cap < 64 { resize() } else { treeify() }
                }
            }
            seen.insert(k); size += 1
            if size > thr { resize() }
        }
        func remove(_ key: K) {
            guard seen.contains(key) else { return }
            var e = first
            while let c = e, c.key != key { e = c.next }
            guard let p = e else { return }
            seen.remove(key); size -= 1
            if !isTree {
                if let pr = p.prev { pr.next = p.next } else { first = p.next }
                p.next?.prev = p.prev
                return
            }
            var root: N? = first
            let succ = p.next, pred = p.prev
            if let pr = pred { pr.next = succ } else { first = succ }
            succ?.prev = pred
            guard first != nil else { isTree = false; return }
            if root?.parent != nil { var r = root!; while let q = r.parent { r = q }; root = r }
            if let rt = root, rt.right == nil || rt.left == nil || rt.left!.left == nil { untreeify(); return }
            let pl = p.left, pr = p.right
            var replacement: N
            if let pl, let pr {
                var s = pr
                while let sl = s.left { s = sl }
                let c = s.red; s.red = p.red; p.red = c
                let sr = s.right
                let pp = p.parent
                if s === pr { p.parent = s; s.right = p }
                else {
                    let sp = s.parent
                    p.parent = sp
                    if let sp { if s === sp.left { sp.left = p } else { sp.right = p } }
                    s.right = pr
                    pr.parent = s
                }
                p.left = nil
                p.right = sr
                sr?.parent = p
                s.left = pl
                pl.parent = s
                s.parent = pp
                if let pp { if p === pp.left { pp.left = s } else { pp.right = s } } else { root = s }
                replacement = sr ?? p
            } else if let pl { replacement = pl }
            else if let pr { replacement = pr }
            else { replacement = p }
            if replacement !== p {
                replacement.parent = p.parent
                if let pp = replacement.parent {
                    if p === pp.left { pp.left = replacement } else { pp.right = replacement }
                } else { root = replacement; replacement.red = false }
                p.left = nil; p.right = nil; p.parent = nil
            }
            let r = p.red ? root : balanceDeletion(root, replacement)
            if replacement === p {
                let pp = p.parent; p.parent = nil
                if let pp { if p === pp.left { pp.left = nil } else if p === pp.right { pp.right = nil } }
            }
            if let r { moveRootToFront(r) }
        }
        func keys() -> [K] {
            var out: [K] = []
            out.reserveCapacity(size)
            var e = first
            while let n = e { out.append(n.key); e = n.next }
            return out
        }
    }
}

// MARK: - Kotlin sortedWith (java.util.TimSort) and compareValuesBy

/// Kotlin `compareValuesBy(a, b, *selectors)`: the first selector whose values differ decides; each is evaluated
/// lazily, a then b, as Kotlin does.
func kotlinCompareBy<T>(_ a: T, _ b: T, _ keys: [(T) -> Int]) -> Int {
    for k in keys {
        let x = k(a), y = k(b)
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

/// Kotlin `sortedWith(comparator)` on a collection: `Arrays.sort(array, comparator)`, i.e. java.util.TimSort - the
/// same comparisons in the same order, so a comparator with side effects (a cache it fills) behaves as on the JVM.
func kotlinSortedWith<S: Sequence>(_ items: S, _ compare: (S.Element, S.Element) -> Int) -> [S.Element] {
    var a = Array(items)
    if a.count > 1 { JavaTimSort.sort(&a, compare) }
    return a
}

enum JavaTimSort {
    private static let minMerge = 32
    private static let minGallopInit = 7

    static func sort<T>(_ a: inout [T], _ c: (T, T) -> Int) {
        var lo = 0
        let hi = a.count
        var nRemaining = hi - lo
        if nRemaining < 2 { return }
        if nRemaining < minMerge {
            let initRunLen = countRunAndMakeAscending(&a, lo, hi, c)
            binarySort(&a, lo, hi, lo + initRunLen, c)
            return
        }
        var ts = State()
        let minRun = minRunLength(nRemaining)
        repeat {
            var runLen = countRunAndMakeAscending(&a, lo, hi, c)
            if runLen < minRun {
                let force = nRemaining <= minRun ? nRemaining : minRun
                binarySort(&a, lo, lo + force, lo + runLen, c)
                runLen = force
            }
            ts.runBase.append(lo); ts.runLen.append(runLen)
            mergeCollapse(&a, &ts, c)
            lo += runLen
            nRemaining -= runLen
        } while nRemaining != 0
        mergeForceCollapse(&a, &ts, c)
    }

    private struct State {
        var minGallop = 7
        var runBase: [Int] = []
        var runLen: [Int] = []
    }

    private static func binarySort<T>(_ a: inout [T], _ lo: Int, _ hi: Int, _ startIn: Int, _ c: (T, T) -> Int) {
        var start = startIn
        if start == lo { start += 1 }
        while start < hi {
            let pivot = a[start]
            var left = lo, right = start
            while left < right {
                let mid = (left + right) >> 1
                if c(pivot, a[mid]) < 0 { right = mid } else { left = mid + 1 }
            }
            var i = start
            while i > left { a[i] = a[i - 1]; i -= 1 }
            a[left] = pivot
            start += 1
        }
    }

    private static func countRunAndMakeAscending<T>(_ a: inout [T], _ lo: Int, _ hi: Int, _ c: (T, T) -> Int) -> Int {
        var runHi = lo + 1
        if runHi == hi { return 1 }
        if c(a[runHi], a[lo]) < 0 {
            runHi += 1
            while runHi < hi && c(a[runHi], a[runHi - 1]) < 0 { runHi += 1 }
            a[lo..<runHi].reverse()
        } else {
            runHi += 1
            while runHi < hi && c(a[runHi], a[runHi - 1]) >= 0 { runHi += 1 }
        }
        return runHi - lo
    }

    private static func minRunLength(_ nIn: Int) -> Int {
        var n = nIn, r = 0
        while n >= minMerge { r |= n & 1; n >>= 1 }
        return n + r
    }

    /// `a` is read through `get` so the same routine serves the main array and the merge's temp copy.
    private static func gallopLeft<T>(_ key: T, _ get: (Int) -> T, _ base: Int, _ len: Int, _ hint: Int, _ c: (T, T) -> Int) -> Int {
        var lastOfs = 0, ofs = 1
        if c(key, get(base + hint)) > 0 {
            let maxOfs = len - hint
            while ofs < maxOfs && c(key, get(base + hint + ofs)) > 0 {
                lastOfs = ofs; ofs = (ofs << 1) + 1
                if ofs <= 0 { ofs = maxOfs }
            }
            if ofs > maxOfs { ofs = maxOfs }
            lastOfs += hint; ofs += hint
        } else {
            let maxOfs = hint + 1
            while ofs < maxOfs && c(key, get(base + hint - ofs)) <= 0 {
                lastOfs = ofs; ofs = (ofs << 1) + 1
                if ofs <= 0 { ofs = maxOfs }
            }
            if ofs > maxOfs { ofs = maxOfs }
            let tmp = lastOfs; lastOfs = hint - ofs; ofs = hint - tmp
        }
        lastOfs += 1
        while lastOfs < ofs {
            let m = lastOfs + ((ofs - lastOfs) >> 1)
            if c(key, get(base + m)) > 0 { lastOfs = m + 1 } else { ofs = m }
        }
        return ofs
    }

    private static func gallopRight<T>(_ key: T, _ get: (Int) -> T, _ base: Int, _ len: Int, _ hint: Int, _ c: (T, T) -> Int) -> Int {
        var ofs = 1, lastOfs = 0
        if c(key, get(base + hint)) < 0 {
            let maxOfs = hint + 1
            while ofs < maxOfs && c(key, get(base + hint - ofs)) < 0 {
                lastOfs = ofs; ofs = (ofs << 1) + 1
                if ofs <= 0 { ofs = maxOfs }
            }
            if ofs > maxOfs { ofs = maxOfs }
            let tmp = lastOfs; lastOfs = hint - ofs; ofs = hint - tmp
        } else {
            let maxOfs = len - hint
            while ofs < maxOfs && c(key, get(base + hint + ofs)) >= 0 {
                lastOfs = ofs; ofs = (ofs << 1) + 1
                if ofs <= 0 { ofs = maxOfs }
            }
            if ofs > maxOfs { ofs = maxOfs }
            lastOfs += hint; ofs += hint
        }
        lastOfs += 1
        while lastOfs < ofs {
            let m = lastOfs + ((ofs - lastOfs) >> 1)
            if c(key, get(base + m)) < 0 { ofs = m } else { lastOfs = m + 1 }
        }
        return ofs
    }

    private static func mergeCollapse<T>(_ a: inout [T], _ ts: inout State, _ c: (T, T) -> Int) {
        while ts.runLen.count > 1 {
            var n = ts.runLen.count - 2
            let rl = ts.runLen
            if (n > 0 && rl[n - 1] <= rl[n] + rl[n + 1]) || (n > 1 && rl[n - 2] <= rl[n] + rl[n - 1]) {
                if rl[n - 1] < rl[n + 1] { n -= 1 }
            } else if n < 0 || rl[n] > rl[n + 1] {
                break
            }
            mergeAt(&a, &ts, n, c)
        }
    }

    private static func mergeForceCollapse<T>(_ a: inout [T], _ ts: inout State, _ c: (T, T) -> Int) {
        while ts.runLen.count > 1 {
            var n = ts.runLen.count - 2
            if n > 0 && ts.runLen[n - 1] < ts.runLen[n + 1] { n -= 1 }
            mergeAt(&a, &ts, n, c)
        }
    }

    private static func mergeAt<T>(_ a: inout [T], _ ts: inout State, _ i: Int, _ c: (T, T) -> Int) {
        var base1 = ts.runBase[i], len1 = ts.runLen[i]
        let base2 = ts.runBase[i + 1]
        var len2 = ts.runLen[i + 1]
        ts.runLen[i] = len1 + len2
        ts.runBase.remove(at: i + 1); ts.runLen.remove(at: i + 1)
        let k = gallopRight(a[base2], { a[$0] }, base1, len1, 0, c)
        base1 += k; len1 -= k
        if len1 == 0 { return }
        len2 = gallopLeft(a[base1 + len1 - 1], { a[$0] }, base2, len2, len2 - 1, c)
        if len2 == 0 { return }
        if len1 <= len2 { mergeLo(&a, &ts, base1, len1, base2, len2, c) }
        else { mergeHi(&a, &ts, base1, len1, base2, len2, c) }
    }

    private static func mergeLo<T>(_ a: inout [T], _ ts: inout State, _ base1: Int, _ len1In: Int, _ base2: Int, _ len2In: Int, _ c: (T, T) -> Int) {
        var len1 = len1In, len2 = len2In
        let tmp = Array(a[base1..<(base1 + len1)])
        var cursor1 = 0, cursor2 = base2, dest = base1
        a[dest] = a[cursor2]; dest += 1; cursor2 += 1
        len2 -= 1
        if len2 == 0 { for j in 0..<len1 { a[dest + j] = tmp[cursor1 + j] }; return }
        if len1 == 1 {
            for j in 0..<len2 { a[dest + j] = a[cursor2 + j] }
            a[dest + len2] = tmp[cursor1]; return
        }
        var minGallop = ts.minGallop
        outer: while true {
            var count1 = 0, count2 = 0
            repeat {
                if c(a[cursor2], tmp[cursor1]) < 0 {
                    a[dest] = a[cursor2]; dest += 1; cursor2 += 1
                    count2 += 1; count1 = 0
                    len2 -= 1
                    if len2 == 0 { break outer }
                } else {
                    a[dest] = tmp[cursor1]; dest += 1; cursor1 += 1
                    count1 += 1; count2 = 0
                    len1 -= 1
                    if len1 == 1 { break outer }
                }
            } while (count1 | count2) < minGallop
            repeat {
                count1 = gallopRight(a[cursor2], { tmp[$0] }, cursor1, len1, 0, c)
                if count1 != 0 {
                    for j in 0..<count1 { a[dest + j] = tmp[cursor1 + j] }
                    dest += count1; cursor1 += count1; len1 -= count1
                    if len1 <= 1 { break outer }
                }
                a[dest] = a[cursor2]; dest += 1; cursor2 += 1
                len2 -= 1
                if len2 == 0 { break outer }
                count2 = gallopLeft(tmp[cursor1], { a[$0] }, cursor2, len2, 0, c)
                if count2 != 0 {
                    for j in 0..<count2 { a[dest + j] = a[cursor2 + j] }
                    dest += count2; cursor2 += count2; len2 -= count2
                    if len2 == 0 { break outer }
                }
                a[dest] = tmp[cursor1]; dest += 1; cursor1 += 1
                len1 -= 1
                if len1 == 1 { break outer }
                minGallop -= 1
            } while count1 >= minGallopInit || count2 >= minGallopInit
            if minGallop < 0 { minGallop = 0 }
            minGallop += 2
        }
        ts.minGallop = minGallop < 1 ? 1 : minGallop
        if len1 == 1 {
            for j in 0..<len2 { a[dest + j] = a[cursor2 + j] }
            a[dest + len2] = tmp[cursor1]
        } else if len1 == 0 {
            preconditionFailure("Comparison method violates its general contract!")
        } else {
            for j in 0..<len1 { a[dest + j] = tmp[cursor1 + j] }
        }
    }

    private static func mergeHi<T>(_ a: inout [T], _ ts: inout State, _ base1: Int, _ len1In: Int, _ base2: Int, _ len2In: Int, _ c: (T, T) -> Int) {
        var len1 = len1In, len2 = len2In
        let tmp = Array(a[base2..<(base2 + len2)])
        var cursor1 = base1 + len1 - 1, cursor2 = len2 - 1, dest = base2 + len2 - 1
        a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1
        len1 -= 1
        if len1 == 0 { for j in 0..<len2 { a[dest - (len2 - 1) + j] = tmp[j] }; return }
        if len2 == 1 {
            dest -= len1; cursor1 -= len1
            var j = len1 - 1
            while j >= 0 { a[dest + 1 + j] = a[cursor1 + 1 + j]; j -= 1 }
            a[dest] = tmp[cursor2]; return
        }
        var minGallop = ts.minGallop
        outer: while true {
            var count1 = 0, count2 = 0
            repeat {
                if c(tmp[cursor2], a[cursor1]) < 0 {
                    a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1
                    count1 += 1; count2 = 0
                    len1 -= 1
                    if len1 == 0 { break outer }
                } else {
                    a[dest] = tmp[cursor2]; dest -= 1; cursor2 -= 1
                    count2 += 1; count1 = 0
                    len2 -= 1
                    if len2 == 1 { break outer }
                }
            } while (count1 | count2) < minGallop
            repeat {
                count1 = len1 - gallopRight(tmp[cursor2], { a[$0] }, base1, len1, len1 - 1, c)
                if count1 != 0 {
                    dest -= count1; cursor1 -= count1; len1 -= count1
                    var j = count1 - 1
                    while j >= 0 { a[dest + 1 + j] = a[cursor1 + 1 + j]; j -= 1 }
                    if len1 == 0 { break outer }
                }
                a[dest] = tmp[cursor2]; dest -= 1; cursor2 -= 1
                len2 -= 1
                if len2 == 1 { break outer }
                count2 = len2 - gallopLeft(a[cursor1], { tmp[$0] }, 0, len2, len2 - 1, c)
                if count2 != 0 {
                    dest -= count2; cursor2 -= count2; len2 -= count2
                    for j in 0..<count2 { a[dest + 1 + j] = tmp[cursor2 + 1 + j] }
                    if len2 <= 1 { break outer }
                }
                a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1
                len1 -= 1
                if len1 == 0 { break outer }
                minGallop -= 1
            } while count1 >= minGallopInit || count2 >= minGallopInit
            if minGallop < 0 { minGallop = 0 }
            minGallop += 2
        }
        ts.minGallop = minGallop < 1 ? 1 : minGallop
        if len2 == 1 {
            dest -= len1; cursor1 -= len1
            var j = len1 - 1
            while j >= 0 { a[dest + 1 + j] = a[cursor1 + 1 + j]; j -= 1 }
            a[dest] = tmp[cursor2]
        } else if len2 == 0 {
            preconditionFailure("Comparison method violates its general contract!")
        } else {
            for j in 0..<len2 { a[dest - (len2 - 1) + j] = tmp[j] }
        }
    }
}
