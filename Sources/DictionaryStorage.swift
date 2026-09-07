import Foundation

/// 個人辞書はアプリ・Git の外で管理する。既存ファイルとリンクは上書きしない。
enum DictionaryStorage {
    struct Configuration: Codable {
        var legacyPaths: [String] = []
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nobetsu", isDirectory: true)
    }

    static func hasEntry(_ url: URL) -> Bool {
        // fileExists は壊れたリンクを false にする。リンクも利用者のデータとして保護する。
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func configuration(in directory: URL) throws -> Configuration {
        let url = directory.appendingPathComponent("dictionary-sources.json")
        guard hasEntry(url) else { return Configuration() }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }

    static func legacyURLs(in directory: URL) throws -> [URL] {
        try configuration(in: directory).legacyPaths.map { URL(fileURLWithPath: $0) }
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        // 後の個人辞書の優先順位を維持する。
        return urls.reversed().filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }.reversed()
    }

    static func createIfMissing(_ data: Data, at url: URL) throws {
        guard !hasEntry(url) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 確認後に別プロセスが作った場合も上書きしない。
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 新しい退避が完成してから古い世代を削除する。作成途中のものを完成品に混ぜない。
    private static func backup(in directory: URL, files: [(URL, Data)], links: [String: String],
                               old: Data?, configuration: Data?) throws {
        let fm = FileManager.default
        let root = directory.appendingPathComponent("dictionary-backups", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let pending = root.appendingPathComponent("." + id + ".partial")
        let completed = root.appendingPathComponent(id)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            for (index, file) in files.enumerated() {
                try createIfMissing(file.1, at: pending.appendingPathComponent("personal-\(index).txt"))
            }
            if let old { try createIfMissing(old, at: pending.appendingPathComponent("previous-bundle.txt")) }
            if let configuration {
                try createIfMissing(configuration, at: pending.appendingPathComponent("dictionary-sources.json"))
            }
            try createIfMissing(try JSONEncoder().encode(files.map { $0.0.path }),
                                at: pending.appendingPathComponent("sources.json"))
            try createIfMissing(try JSONEncoder().encode(links),
                                at: pending.appendingPathComponent("links.json"))
            try fm.moveItem(at: pending, to: completed)
        } catch {
            try? fm.removeItem(at: pending)
            throw error
        }
        // 旧版の UUID フォルダも対象。利用者が置いたファイルやリンクは刈り取らない。
        let generations = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url -> (url: URL, date: Date)? in
                guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
                let attrs = try fm.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
                return (url, attrs[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted {
                $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date
            }
            .map(\.url)
        // 列挙したディレクトリURLは末尾スラッシュが付くため、UUID名で今回分を除外する。
        // 時計が巻き戻っても今回のバックアップは残す。
        for url in generations.filter({ $0.lastPathComponent != id }).dropFirst(4) {
            try fm.removeItem(at: url)
        }
    }

    /// 設置前だけ実行。退避に失敗したら throw し、旧アプリを残す。
    /// 壊れた記録や消えたリンク先は保存場所を返し、既存データを変更せず更新を続ける。
    @discardableResult
    static func prepare(in directory: URL, repositoryDictionary: URL,
                        previousBundle: URL?, sample: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let personal = directory.appendingPathComponent("dictionary.txt")
        let configURL = directory.appendingPathComponent("dictionary-sources.json")
        let migrated = hasEntry(configURL)
        var issues: [URL] = []
        var links: [String: String] = [:]
        // 保護対象の有無と、実体を読めるかは別。リンク自体も復旧用に記録する。
        func snapshot(_ url: URL) throws -> Data? {
            if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                links[url.path] = target
                if !fm.fileExists(atPath: url.path) {
                    issues.append(url)
                    return nil
                }
            }
            return try Data(contentsOf: url)
        }
        let configData = migrated ? try snapshot(configURL) : nil
        var config = Configuration()
        if let configData {
            do { config = try JSONDecoder().decode(Configuration.self, from: configData) }
            catch { issues.append(configURL) }
        }
        let repositoryExists = hasEntry(repositoryDictionary)
        let old = try previousBundle.map { try Data(contentsOf: $0) }
        let sampleData = try Data(contentsOf: sample)
        let active = unique(config.legacyPaths.map { URL(fileURLWithPath: $0) }
            + (repositoryExists ? [repositoryDictionary] : []) + (hasEntry(personal) ? [personal] : []))
        var snapshots: [(URL, Data)] = []
        for url in active {
            guard hasEntry(url) else { issues.append(url); continue }
            if let data = try snapshot(url) { snapshots.append((url, data)) }
        }
        if !snapshots.isEmpty || old != nil || migrated || !links.isEmpty {
            try backup(in: directory, files: snapshots, links: links, old: old, configuration: configData)
        }
        // 壊れた記録を初期化したり、移行済みの古い規則を再取り込みしたりしない。
        guard issues.isEmpty else { return issues }
        guard !migrated else { return [] }

        if repositoryExists {
            if !hasEntry(personal) {
                // 新規の引き継ぎはコピー。git clean で個人辞書の実体まで消えないようにする。
                try createIfMissing(try Data(contentsOf: repositoryDictionary), at: personal)
            } else if personal.resolvingSymlinksInPath() != repositoryDictionary.resolvingSymlinksInPath() {
                config.legacyPaths.append(repositoryDictionary.path)
            }
        } else if let old, old != sampleData {
            if !hasEntry(personal) {
                try createIfMissing(old, at: personal)
            } else {
                let recovered = directory.appendingPathComponent("legacy-dictionary-" + UUID().uuidString + ".txt")
                try createIfMissing(old, at: recovered)
                config.legacyPaths.append(recovered.path)
            }
        }
        config.legacyPaths = unique(config.legacyPaths.map { URL(fileURLWithPath: $0) }).map(\.path)
        try createIfMissing(try JSONEncoder().encode(config), at: configURL)
        return []
    }
}
