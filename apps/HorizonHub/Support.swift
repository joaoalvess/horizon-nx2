import Foundation

enum Background {
    static let queue = DispatchQueue(label: "dev.joaoalvess.horizon.hub.work", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}

enum Format {
    static let locale = Locale(identifier: "en_US")

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: locale))
    }

    static func explain(_ error: Error) -> String {
        String(describing: error)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
