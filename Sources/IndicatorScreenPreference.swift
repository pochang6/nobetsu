import Foundation

/// 接続順や一時的な画面番号ではなく、モニターの UUID で固定先を覚える。
struct IndicatorScreenPreference: Codable, Equatable, Identifiable {
    let id: String
    let name: String

    static let defaultsKey = "nobetsu.indicatorFixedScreen"

    func index(in screenIDs: [String?]) -> Int? {
        screenIDs.firstIndex { $0 == id }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.id.isEmpty else { return nil }
        return value
    }

    static func save(_ value: Self?, to defaults: UserDefaults = .standard) {
        guard let value else { defaults.removeObject(forKey: defaultsKey); return }
        defaults.set(try? JSONEncoder().encode(value), forKey: defaultsKey)
    }
}
