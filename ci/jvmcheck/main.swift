// Replays the JVM reference files against Shell/JavaCompat.swift (compiled standalone on the CI runner).
import Foundation

func lines(_ path: String) -> [Substring] { (try! String(contentsOfFile: path, encoding: .utf8)).split(separator: "\n") }
func javaHash(_ s: String) -> Int32 { var h: Int32 = 0; for u in s.utf16 { h = h &* 31 &+ Int32(u) }; return h }
let dir = CommandLine.arguments[1]
var failures = 0

// 1. JavaHash1Set: HashSet() / HashSet(cap), inserts 0..<n then every 7th again
var ok1 = 0, n1 = 0
for l in lines(dir + "/ref.txt") {
    let parts = l.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let head = parts[0].split(separator: " ").map { Int($0)! }
    let want = parts.count > 1 ? parts[1].split(separator: " ").map { Int($0)! } : []
    let (cap, n) = (head[0], head[1])
    let ins = Array(0..<n) + Array(stride(from: 0, to: n, by: 7))
    let got = JavaHash1Set.iterationOrder(ins, initialCapacity: cap < 0 ? nil : cap)
    n1 += 1; if got == want { ok1 += 1 } else if failures < 5 { failures += 1; print("HASH MISMATCH cap \(cap) n \(n)") }
}
print("JavaHash1Set: \(ok1)/\(n1)")

// 2. HashSet(collection): jdk19CollectionCapacity
var ok2 = 0, n2 = 0
for l in lines(dir + "/refcap.txt") {
    let parts = l.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let n = Int(parts[0])!
    let want = parts.count > 1 ? parts[1].split(separator: " ").map { Int($0)! } : []
    let got = JavaHash1Set.iterationOrder(Array(0..<n), initialCapacity: JavaHash1Set.jdk19CollectionCapacity(n))
    n2 += 1; if got == want { ok2 += 1 }
}
print("jdk19CollectionCapacity: \(ok2)/\(n2)")

// 3. TimSort: same comparator-call sequence (Java String.hashCode of "x,y;..." + count) and same result
var ok3 = 0, n3 = 0
for l in lines(dir + "/refsort.txt") {
    let f = l.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let keys = f[1].dropFirst().dropLast().split(separator: ",").map { Int($0)! }
    var calls = ""; var count = 0
    let sorted = kotlinSortedWith(Array(0..<keys.count)) { x, y in
        calls += "\(x),\(y);"; count += 1
        return keys[x] < keys[y] ? -1 : keys[x] > keys[y] ? 1 : 0
    }
    let sig = count == 0 ? "0:0" : "\(javaHash(calls)):\(count)"
    let ids = "[" + sorted.map(String.init).joined(separator: ",") + "]"
    n3 += 1; if sig == f[2] && ids == f[3] { ok3 += 1 } else if failures < 10 { failures += 1; print("SORT MISMATCH n \(keys.count): want \(f[2]) got \(sig)") }
}
print("kotlinSortedWith (TimSort): \(ok3)/\(n3)")
// 4. remove() and a cleared set refilled with its old table length
var ok4 = 0, n4 = 0
for l in lines(dir + "/refremove.txt") {
    let parts = l.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let h = parts[0].split(separator: " ").map(String.init)
    let want = parts.count > 1 ? parts[1].split(separator: " ").map { Int($0)! } : []
    var good: Bool
    if h[0] == "R" {
        let n = Int(h[1])!, r = Int(h[2])!
        good = JavaHash1Set.iterationOrder(Array(0..<n), removing: r) == want
    } else {
        let n1 = Int(h[1])!, len1 = Int(h[2])!, n2 = Int(h[3])!, len2 = Int(h[4])!
        let first = JavaHash1Set.iterationOrderAndTableLength(Array(0..<n1))
        let second = JavaHash1Set.iterationOrderAndTableLength(Array(0..<n2), initialCapacity: first.tableLength > 0 ? first.tableLength : nil)
        good = second.order == want && first.tableLength == len1 && (n2 > 0 ? second.tableLength : first.tableLength) == len2
    }
    n4 += 1; if good { ok4 += 1 } else if failures < 15 { failures += 1; print("REMOVE/TABLE MISMATCH \(l.prefix(40))") }
}
print("JavaHash1Set remove/table: \(ok4)/\(n4)")
exit(ok1 == n1 && ok2 == n2 && ok3 == n3 && ok4 == n4 ? 0 : 1)
