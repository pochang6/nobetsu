import Foundation

/// 非同期の準備・終了と次の収録を混ぜないための状態。デバイスなしで検証する。
struct DictationLifecycle {
    enum Phase { case idle, preparing, running, stopping }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0
    var isActive: Bool { phase == .preparing || phase == .running }

    mutating func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .preparing
        return generation
    }

    func accepts(_ token: UInt64) -> Bool { generation == token && isActive }

    mutating func didStart(_ token: UInt64) -> Bool {
        guard accepts(token), phase == .preparing else { return false }
        phase = .running
        return true
    }

    mutating func stop() -> UInt64? {
        guard isActive else { return nil }
        phase = .stopping
        return generation
    }

    mutating func didStop(_ token: UInt64) {
        guard generation == token, phase == .stopping else { return }
        phase = .idle
    }
}
