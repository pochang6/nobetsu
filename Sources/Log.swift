import Foundation

/// 何が起きたかを後から追えるようにする。
///
/// メニューバー常駐アプリは画面に出せる情報が少なく、
/// 「一瞬動いて止まった」が起きても原因が残らない。
/// ~/Library/Logs/nobetsu.log に淡々と書き出す。
enum Log {

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

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// 起動のたびに区切りを入れる。どの起動の記録かを見分けるため
    static func startSession() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        write("──────── 起動 \(stamp) ────────")
    }
}
