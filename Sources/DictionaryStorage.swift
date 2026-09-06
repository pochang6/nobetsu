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

    static func exists(_ url: URL) -> Bool {
        // fileExists は壊れたリンクを false にする。リンクも利用者のデータとして保護する。
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func configuration(in directory: URL) throws -> Configuration {
        let url = directory.appendingPathComponent("dictionary-sources.json")
        guard exists(url) else { return Configuration() }
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
        guard !exists(url) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 確認後に別プロセスが作った場合も上書きしない。
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 設置前だけ実行。退避に失敗したら throw し、旧アプリを残す。
    /// 旧同梱辞書だけに残る語彙も回収する。移行済みなら再取り込みしない。
    static func prepare(in directory: URL, repositoryDictionary: URL,
                        previousBundle: URL?, sample: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let personal = directory.appendingPathComponent("dictionary.txt")
        let configURL = directory.appendingPathComponent("dictionary-sources.json")
        let migrated = exists(configURL)
        var config = try configuration(in: directory)
        let repositoryExists = exists(repositoryDictionary)
        let old = try previousBundle.map { try Data(contentsOf: $0) }
        let sampleData = try Data(contentsOf: sample)

        // 読めないファイル・壊れたリンクを空の辞書で置き換えない。
        let active = unique((try legacyURLs(in: directory))
            + (repositoryExists ? [repositoryDictionary] : []) + (exists(personal) ? [personal] : []))
        let existing = active.filter { exists($0) }
        let snapshots = try existing.map { try Data(contentsOf: $0) }
        if !snapshots.isEmpty || old != nil {
            let backup = directory.appendingPathComponent("dictionary-backups/" + UUID().uuidString)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for (index, data) in snapshots.enumerated() {
                try createIfMissing(data, at: backup.appendingPathComponent("personal-\(index).txt"))
            }
            if let old { try createIfMissing(old, at: backup.appendingPathComponent("previous-bundle.txt")) }
            // 復旧時に元の保存場所が分かる。これもローカルだけに保存する。
            try createIfMissing(try JSONEncoder().encode(existing.map(\.path)),
                                at: backup.appendingPathComponent("sources.json"))
        }

        if repositoryExists {
            if !exists(personal) {
                try fm.createSymbolicLink(at: personal, withDestinationURL: repositoryDictionary)
            } else if personal.resolvingSymlinksInPath() != repositoryDictionary.resolvingSymlinksInPath() {
                config.legacyPaths.append(repositoryDictionary.path)
            }
        } else if !migrated, let old, old != sampleData {
            if !exists(personal) {
                try createIfMissing(old, at: personal)
            } else {
                // 個人辞書と旧同梱辞書が別物なら、どちらも残す。
                // 利用者のファイルへ勝手にマージしない。メニューから別々に編集できる。
                let recovered = directory.appendingPathComponent("legacy-dictionary-" + UUID().uuidString + ".txt")
                try createIfMissing(old, at: recovered)
                config.legacyPaths.append(recovered.path)
            }
        }
        config.legacyPaths = unique(config.legacyPaths.map { URL(fileURLWithPath: $0) }).map(\.path)
        let encoded = try JSONEncoder().encode(config)
        if migrated {
            try encoded.write(to: configURL, options: .atomic)
        } else {
            try createIfMissing(encoded, at: configURL)
        }
    }
}
