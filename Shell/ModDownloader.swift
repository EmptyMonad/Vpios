// Shell for the Unciv 4X core (MPL-2.0): mod browsing and installing from GitHub, after Unciv's Github.kt /
// ModManagementScreen (repositories tagged `unciv-mod`; a mod is a repository's default-branch zip, unpacked into
// Documents/Mods/<repo name with '-' as ' '>). Written fresh here.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Compression

enum ModDownloader {
    struct Owner: Codable, Hashable { let login: String }

    struct Repo: Codable, Identifiable, Hashable {
        let name: String
        var full_name: String? = nil
        let html_url: String
        var description: String? = nil
        var owner: Owner? = nil
        var topics: [String]? = nil
        var pushed_at: String? = nil
        var stargazers_count: Int = 0
        var default_branch: String? = nil
        var size: Int? = nil
        /// a direct archive link (Download from URL with a zip or a branch)
        var directZip: String? = nil

        var id: String { full_name ?? html_url }
        /// Unciv Repo.toModFolderName: the repository name with '-' as ' '
        var folderName: String { name.replacingOccurrences(of: "-", with: " ") }

        enum CodingKeys: String, CodingKey {
            case name, full_name, html_url, description, owner, topics, pushed_at, stargazers_count, default_branch, size, directZip
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            full_name = try c.decodeIfPresent(String.self, forKey: .full_name)
            html_url = try c.decodeIfPresent(String.self, forKey: .html_url) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description)
            owner = try c.decodeIfPresent(Owner.self, forKey: .owner)
            topics = try c.decodeIfPresent([String].self, forKey: .topics)
            pushed_at = try c.decodeIfPresent(String.self, forKey: .pushed_at)
            stargazers_count = try c.decodeIfPresent(Int.self, forKey: .stargazers_count) ?? 0
            default_branch = try c.decodeIfPresent(String.self, forKey: .default_branch)
            size = try c.decodeIfPresent(Int.self, forKey: .size)
            directZip = try c.decodeIfPresent(String.self, forKey: .directZip)
        }
        init(name: String, html_url: String, owner: String?, branch: String?, directZip: String?) {
            self.name = name; self.html_url = html_url; self.owner = owner.map { Owner(login: $0) }
            self.full_name = owner.map { "\($0)/\(name)" }; self.default_branch = branch; self.directZip = directZip
        }
    }

    struct Page: Decodable { let total_count: Int; let items: [Repo] }

    struct Category { let topic: String; let label: String }
    /// Unciv ModCategories (jsons/ModCategories.json)
    static let categories: [Category] = [
        Category(topic: "unciv-mod", label: "All mods"),
        Category(topic: "unciv-mod-rulesets", label: "Rulesets"),
        Category(topic: "unciv-mod-expansions", label: "Expansions"),
        Category(topic: "unciv-mod-graphics", label: "Graphics"),
        Category(topic: "unciv-mod-audio", label: "Audio"),
        Category(topic: "unciv-mod-maps", label: "Maps"),
        Category(topic: "unciv-mod-fun", label: "Fun"),
        Category(topic: "unciv-mod-modsofmods", label: "Mods of mods"),
    ]

    enum ModError: LocalizedError {
        case notFound(String), badArchive(String), network(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let n): return "Could not download [\(n)]"
            case .badArchive(let n): return "[\(n)] is not a valid mod archive"
            case .network(let m): return m
            }
        }
    }

    // MARK: GitHub

    private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("vpios", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ModError.network("No response") }
        return (data, http)
    }

    /// Unciv Github.tryGetGithubReposWithTopic
    static func fetchPage(_ page: Int, amountPerPage: Int, search: String = "") async throws -> Page {
        var c = URLComponents(string: "https://api.github.com/search/repositories")!
        let q = (search.isEmpty ? "" : search + " ") + "topic:unciv-mod fork:true"
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "sort", value: "stars"),
                        URLQueryItem(name: "per_page", value: String(amountPerPage)), URLQueryItem(name: "page", value: String(page))]
        let (data, http) = try await get(c.url!)
        guard http.statusCode == 200 else { throw ModError.network("GitHub: HTTP \(http.statusCode)") }
        return try JSONDecoder().decode(Page.self, from: data)
    }

    /// Every page; returns true when the list may be incomplete (GitHub caps search results at 1000).
    static func fetchAllMods(onPage: @MainActor ([Repo]) -> Void) async throws -> Bool {
        var page = 1, got = 0
        while true {
            let p = try await fetchPage(page, amountPerPage: 100)
            await onPage(p.items)
            got += p.items.count
            if p.items.count < 100 || got >= p.total_count { return false }
            if got >= 1000 { return true }
            page += 1
        }
    }

    static func repoSize(_ r: Repo) async -> Int? {
        if let s = r.size { return s }
        guard let full = r.full_name, let url = URL(string: "https://api.github.com/repos/\(full)"),
              let (data, http) = try? await get(url), http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["size"] as? Int
    }

    static func sizeText(_ kB: Int) -> String { kB >= 1024 ? "Size: [\(kB / 1024)] MB" : "Size: [\(kB)] kB" }

    /// Unciv Repo.parseUrl: github.com/owner/repo, .../tree/branch, .../archive/....zip, or any direct .zip link
    static func installFromURL(_ text: String) async throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let host = url.host else { throw URLError(.badURL) }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("github.com"), parts.count >= 2 {
            let owner = parts[0], repo = parts[1].replacingOccurrences(of: ".git", with: "")
            var branch: String? = nil
            if parts.count >= 4, parts[2] == "tree" { branch = parts[3...].joined(separator: "/") }
            if t.lowercased().hasSuffix(".zip") {
                return try await install(Repo(name: repo, html_url: "https://github.com/\(owner)/\(repo)", owner: owner, branch: nil, directZip: t))
            }
            var r = Repo(name: repo, html_url: "https://github.com/\(owner)/\(repo)", owner: owner, branch: branch, directZip: nil)
            if let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)"), let (data, http) = try? await get(api), http.statusCode == 200,
               let full = try? JSONDecoder().decode(Repo.self, from: data) {
                let b = r.default_branch; r = full; if let b { r.default_branch = b }
            }
            return try await install(r)
        }
        guard t.lowercased().hasSuffix(".zip") else { throw URLError(.badURL) }
        let name = url.deletingPathExtension().lastPathComponent
        return try await install(Repo(name: name, html_url: t, owner: nil, branch: nil, directZip: t))
    }

    /// Download the archive, unpack it into Documents/Mods/<folderName>, remember where it came from.
    static func install(_ r: Repo) async throws -> String {
        let zipURL: URL
        if let z = r.directZip, let u = URL(string: z) { zipURL = u }
        else if let full = r.full_name ?? r.owner.map({ "\($0.login)/\(r.name)" }) {
            let branch = r.default_branch ?? "HEAD"
            guard let u = URL(string: "https://codeload.github.com/\(full)/zip/\(branch == "HEAD" ? "HEAD" : "refs/heads/" + branch)")
            else { throw ModError.notFound(r.folderName) }
            zipURL = u
        } else { throw ModError.notFound(r.folderName) }
        let (data, http) = try await get(zipURL)
        guard http.statusCode == 200 else { throw ModError.notFound(r.folderName) }
        let entries = try ZipReader.entries(data)
        // strip the archive's single top-level folder ("repo-branch/")
        let names = entries.map(\.name).filter { !$0.isEmpty }
        let tops = Set(names.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
        let strip = tops.count == 1 && names.allSatisfy { $0.contains("/") } ? tops.first! + "/" : ""
        let dest = Ruleset.modsDirectory.appendingPathComponent(r.folderName)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for e in entries {
            var rel = e.name
            if !strip.isEmpty { guard rel.hasPrefix(strip) else { continue }; rel.removeFirst(strip.count) }
            if rel.isEmpty || rel.hasSuffix("/") || rel.contains("..") { continue }
            let out = tmp.appendingPathComponent(rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.data().write(to: out)
        }
        let hasJsons = fm.fileExists(atPath: tmp.appendingPathComponent("jsons").path)
        let hasImages = fm.fileExists(atPath: tmp.appendingPathComponent("Images").path)
        guard hasJsons || hasImages || fm.fileExists(atPath: tmp.appendingPathComponent("maps").path) else {
            try? fm.removeItem(at: tmp); throw ModError.badArchive(r.folderName)
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        var meta = r; if meta.pushed_at == nil { meta.pushed_at = ISO8601DateFormatter().string(from: Date()) }
        if let m = try? JSONEncoder().encode(meta) { try? m.write(to: dest.appendingPathComponent(metaFile)) }
        return r.folderName
    }

    static func remove(_ mod: String) {
        try? FileManager.default.removeItem(at: Ruleset.modsDirectory.appendingPathComponent(mod))
    }

    // MARK: installed mods' metadata

    private static let metaFile = ".vpios-repo.json"
    private static func installedRepo(_ mod: String) -> Repo? {
        let u = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent(metaFile)
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Repo.self, from: d)
    }
    private static func modOptions(_ mod: String) -> [String: Any] {
        let u = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent("jsons/ModOptions.json")
        guard let raw = try? Data(contentsOf: u), let c = Ruleset.cleanedModJSON(raw),
              let o = try? JSONSerialization.jsonObject(with: c) as? [String: Any] else { return [:] }
        return o
    }
    static func installedAuthor(_ mod: String) -> String {
        installedRepo(mod)?.owner?.login ?? (modOptions(mod)["author"] as? String) ?? ""
    }
    static func installedTopics(_ mod: String) -> [String] {
        installedRepo(mod)?.topics ?? (modOptions(mod)["topics"] as? [String]) ?? []
    }
    static func installedLastUpdated(_ mod: String) -> Date {
        if let p = installedRepo(mod)?.pushed_at, let d = ISO8601DateFormatter().date(from: p) { return d }
        let attrs = try? FileManager.default.attributesOfItem(atPath: Ruleset.modsDirectory.appendingPathComponent(mod).path)
        return attrs?[.modificationDate] as? Date ?? .distantPast
    }
    /// Unciv: an installed mod is outdated when the repository was pushed after the installed copy's lastUpdated
    static func installedIsOutdated(_ r: Repo) -> Bool {
        guard let p = r.pushed_at, let online = ISO8601DateFormatter().date(from: p) else { return false }
        return online > installedLastUpdated(r.folderName)
    }

    /// Unciv ModManagementScreen filter: text in name or author, and the category topic
    static func matchesFilter(name: String, author: String, topics: [String], text: String, topic: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.isEmpty && !name.lowercased().contains(t) && !author.lowercased().contains(t) { return false }
        if topic.isEmpty || topic == "unciv-mod" { return true }
        return topics.contains(topic)
    }
}

/// Minimal ZIP reader: central directory, stored and deflated entries (Compression's ZLIB is raw deflate).
enum ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressed: Data
        let size: Int
        func data() throws -> Data {
            if method == 0 { return compressed }
            guard method == 8 else { throw ModDownloader.ModError.badArchive(name) }
            if size == 0 { return Data() }
            var out = Data(count: size)
            let n = out.withUnsafeMutableBytes { dst in
                compressed.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == size else { throw ModDownloader.ModError.badArchive(name) }
            return out
        }
    }

    static func entries(_ d: Data) throws -> [Entry] {
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw ModDownloader.ModError.badArchive("archive") }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65535) {
            if b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ModDownloader.ModError.badArchive("archive") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw ModDownloader.ModError.badArchive("archive") }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            guard local + 30 <= b.count, u32(local) == 0x04034b50 else { throw ModDownloader.ModError.badArchive(name) }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { throw ModDownloader.ModError.badArchive(name) }
            out.append(Entry(name: name, method: method, compressed: d.subdata(in: start..<(start + csize)), size: usize))
            p += 46 + nlen + xlen + clen
        }
        return out
    }
}
