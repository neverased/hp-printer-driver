import Foundation

/// Runs the public scan CLI without blocking the main thread or retaining image data.
@MainActor
final class ScannerProcess {
    private var process: Process?
    private var cancelled = false

    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true
        process.terminate()
    }

    func scan(configuration: ScannerConfiguration, script: URL,
              settings: ScanSettings, output: URL) async throws -> ScanResult {
        guard process == nil else {
            throw ScanFailure(message: "Skanowanie już trwa.", details: nil)
        }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: configuration.pythonPath),
              manager.isExecutableFile(atPath: configuration.runtimePath + "/prefix/bin/scanimage"),
              manager.fileExists(atPath: script.path) else {
            throw ScanFailure(message: "Nie znaleziono składników skanera.",
                              details: "Ta wersja aplikacji korzysta z lokalnego środowiska w repozytorium. Uruchom scripts/build-sane.sh, a następnie scripts/build-scanner-app.sh.")
        }
        let temporary = manager.temporaryDirectory.appendingPathComponent("HP150Scanner-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let stdoutURL = temporary.appendingPathComponent("stdout.json")
        let stderrURL = temporary.appendingPathComponent("stderr.txt")
        for url in [stdoutURL, stderrURL] {
            guard manager.createFile(atPath: url.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
                try? manager.removeItem(at: temporary)
                throw ScanFailure(message: "Nie można przygotować pliku tymczasowego.", details: nil)
            }
        }
        let stdout: FileHandle
        let stderr: FileHandle
        do {
            stdout = try FileHandle(forWritingTo: stdoutURL)
            stderr = try FileHandle(forWritingTo: stderrURL)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        task.arguments = ["-arm64", configuration.pythonPath, script.path,
                          "--runtime", configuration.runtimePath, "--output", output.path,
                          "--dpi", String(settings.dpi), "--mode", settings.mode,
                          "--paper", settings.paper]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = stdout
        task.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = environment
        cancelled = false
        process = task

        return try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { [weak self] task in
                let status = task.terminationStatus
                Task { @MainActor in
                    let manager = FileManager.default
                    try? stdout.close()
                    try? stderr.close()
                    defer { try? manager.removeItem(at: temporary) }
                    let wasCancelled = self?.cancelled ?? false
                    self?.process = nil
                    // Publication may finish just before a cancellation request.
                    // Keep a successful, validated result visible to the user.
                    if status == 130 || (wasCancelled && status != 0) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        guard status == 0 else {
                            let details = try Self.readLimited(stderrURL)
                            throw ScanFailure(
                                message: "Nie udało się wykonać skanu. Sprawdź USB i kartkę, a następnie spróbuj ponownie.",
                                details: Self.redact(details.isEmpty ? "Proces zakończył się kodem \(status)." : details))
                        }
                        let data = try Data(contentsOf: stdoutURL)
                        let result = try JSONDecoder().decode(ScanResult.self, from: data)
                        guard result.width > 0, result.height > 0,
                              URL(fileURLWithPath: result.path).standardizedFileURL == output.standardizedFileURL,
                              manager.fileExists(atPath: result.path) else {
                            throw ScanFailure(message: "Nie można potwierdzić zapisanego skanu.", details: nil)
                        }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            do {
                try task.run()
            } catch {
                process = nil
                task.terminationHandler = nil
                try? stdout.close()
                try? stderr.close()
                try? manager.removeItem(at: temporary)
                continuation.resume(throwing: error)
            }
        }
    }

    private static func readLimited(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)(?:hpaio|hp):/[^\s'\"`]+"#,
                                   with: "HP Officejet 150 (USB)", options: .regularExpression)
    }
}
