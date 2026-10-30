import Foundation

struct ScanSettings: Sendable {
    var dpi = 300
    var mode = "Color"
    var paper = "A4"
    static let resolutions = [75, 100, 150, 200, 300, 600]
}

struct ScanResult: Decodable, Sendable {
    let path: String
    let width: Int
    let height: Int
    let dpi: Int
}

struct ScannerConfiguration: Decodable, Sendable {
    let runtimePath: String
    let pythonPath: String

    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "runtime", withExtension: "json") else {
            throw ScanFailure(message: "Brakuje konfiguracji aplikacji.",
                              details: "Uruchom ponownie scripts/build-scanner-app.sh w repozytorium.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

struct ScanFailure: LocalizedError, Sendable {
    let message: String
    let details: String?
    var errorDescription: String? { message }
}
