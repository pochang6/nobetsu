import Foundation
import Compression

/// 何が起きたかを後から追えるようにする。
///
/// メニューバー常駐アプリは画面に出せる情報が少なく、
/// 「一瞬動いて止まった」が起きても原因が残らない。
/// ~/Library/Logs/nobetsu.log に淡々と書き出す。
///
/// **喋った内容そのものは書きません。** 残すのは時刻・アプリ名・文字数だけです。
/// 打ち込んだ文字を残せば調査は楽になりますが、
/// このアプリのログは「利用者が一日じゅう喋った内容の写し」になってしまいます。
///
/// 追記しかしないので放っておけば際限なく育ちます。
/// 1MB を超えたところで圧縮して退避し、いまのファイルを含めて5世代だけ残します。
enum Log {

    /// ここを超えたら退避する。実測で1日 40KB ほど（かなり喋った日）なので、
    /// 1MB あれば直近の3〜4週間はいつでも読める
    static let maxBytes = 1024 * 1024

    /// いまのファイルを含めて何世代残すか。nobetsu.log + .1.gz 〜 .4.gz
    static let generations = 5

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("nobetsu.log")
    }()

    private static let queue = DispatchQueue(label: "dev.pochang6.nobetsu.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// いまのファイルの大きさ。1行ごとに stat を叩かないための覚え。
    /// nil は「まだ実ファイルを見ていない」。**queue の上でだけ触ること**
    nonisolated(unsafe) private static var knownBytes: Int?

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            append(line)
            rotateIfNeeded()
        }
    }

    /// 起動のたびに区切りを入れる。どの起動の記録かを見分けるため
    static func startSession() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        write("──────── 起動 \(stamp) ────────")
    }

    // MARK: - 書き込み

    /// queue の上でだけ呼ぶ
    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let before = currentBytes()   // 書いたあとに数えると、実ファイルを見た分と二重になる
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        knownBytes = before + data.count
    }

    /// queue の上でだけ呼ぶ
    private static func currentBytes() -> Int {
        if let known = knownBytes { return known }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        knownBytes = size
        return size
    }

    // MARK: - 退避

    /// queue の上でだけ呼ぶ
    private static func rotateIfNeeded() {
        guard currentBytes() >= maxBytes else { return }
        rotate()
    }

    /// いまのファイルを .1.gz へ送り、古い世代を1つずつ繰り下げる。
    ///
    /// 圧縮に失敗したときは `.gz` を付けずにそのまま置く。
    /// **圧縮できなかったものに .gz の名前を付けない**のは、
    /// 後から zcat した人が「壊れている」と思うより、素直に読める方がましだから
    private static func rotate() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        let url = { (name: String) in dir.appendingPathComponent(name) }

        // いちばん古い世代を捨てる（.4）
        let oldest = generations - 1
        for compressed in [true, false] {
            try? fm.removeItem(at: url(archiveName(base, oldest, compressed: compressed)))
        }

        // 繰り下げる（.3 → .4, .2 → .3, .1 → .2）
        for index in stride(from: oldest - 1, through: 1, by: -1) {
            for compressed in [true, false] {
                let from = url(archiveName(base, index, compressed: compressed))
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = url(archiveName(base, index + 1, compressed: compressed))
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }

        // いまのファイルを圧縮して .1.gz へ
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let packed = gzipped(data, mtime: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        let dest = url(archiveName(base, 1, compressed: packed != nil))
        try? fm.removeItem(at: dest)
        do {
            try (packed ?? data).write(to: dest)
        } catch {
            return   // 置けないなら消さない。消してしまうと記録が丸ごと消える
        }
        try? fm.removeItem(at: fileURL)
        knownBytes = 0

        // 続きから読む人が「前半が消えた」と誤解しないように、行き先を書いておく
        append("[\(formatter.string(from: Date()))] ──────── ここより前は \(dest.lastPathComponent) ────────\n")
    }

    /// 退避先の名前。nobetsu.log → nobetsu.log.1.gz
    static func archiveName(_ base: String, _ index: Int, compressed: Bool) -> String {
        compressed ? "\(base).\(index).gz" : "\(base).\(index)"
    }

    // MARK: - gzip

    /// gzip 形式（RFC 1952）に包む。gunzip や zcat でそのまま読める。
    ///
    /// 圧縮そのものは OS の Compression が持っている。
    /// ただし COMPRESSION_ZLIB が返すのは**ヘッダの無い生の DEFLATE** なので、
    /// gzip のヘッダと、末尾の CRC32・元の長さは自分で付ける
    static func gzipped(_ data: Data, mtime: UInt32 = 0) -> Data? {
        guard let body = deflated(data) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00])            // 魔法の2バイト / DEFLATE / フラグなし
        out.append(contentsOf: littleEndian(mtime))          // 元のファイルの時刻
        out.append(contentsOf: [0x00, 0x03])                 // 圧縮の強さは指定なし / Unix
        out.append(body)
        out.append(contentsOf: littleEndian(crc32(data)))
        out.append(contentsOf: littleEndian(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    /// ヘッダの無い生の DEFLATE（RFC 1951）
    static func deflated(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }   // 空を表す最短の形
        return data.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // DEFLATE は縮まない入力をわずかに膨らませる。余白は多めに取る
            let capacity = data.count + 64 * 1024
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let n = compression_encode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
            guard n > 0 else { return nil }
            return Data(bytes: dst, count: n)
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}
