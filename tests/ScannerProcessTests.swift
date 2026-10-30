import Foundation

private struct TestFailure: Error {
    let message: String
}

@main
struct ScannerProcessTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message: message) }
    }

    @MainActor
    static func waitFor(_ marker: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure(message: "Fixture did not reach \(marker.lastPathComponent)")
    }

    @MainActor
    static func runTests() async throws {
        let script = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("HP150ProcessTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("prefix/bin"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Satisfy the service's prerequisite check; the fixture never executes this.
        try FileManager.default.createSymbolicLink(
            at: temporary.appendingPathComponent("prefix/bin/scanimage"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let configuration = ScannerConfiguration(runtimePath: temporary.path,
                                                 pythonPath: CommandLine.arguments[2])
        let service = ScannerProcess()
        let output = temporary.appendingPathComponent("normal.png")
        let result = try await service.scan(configuration: configuration, script: script,
                                            settings: ScanSettings(), output: output)
        try require(result.width == 2480 && result.height == 3507 && result.path == output.path,
                    "Successful process result was not returned")
        print("PASS: successful process result reaches caller")

        var failedSettings = ScanSettings()
        failedSettings.paper = "Letter"
        do {
            _ = try await service.scan(configuration: configuration, script: script,
                                       settings: failedSettings, output: temporary.appendingPathComponent("error.png"))
            throw TestFailure(message: "CLI failure was not propagated")
        } catch let error as ScanFailure {
            try require(error.details?.contains("PRIVATE") == false, "Device serial was exposed")
            try require(error.details?.contains("Fixture error") == true, "Failure details were lost")
        }
        print("PASS: CLI failure is surfaced with device URI redacted")

        var slowSettings = ScanSettings()
        slowSettings.paper = "Legal"
        let slowOutput = temporary.appendingPathComponent("cancelled.png")
        let first = Task { @MainActor in
            try await service.scan(configuration: configuration, script: script,
                                   settings: slowSettings, output: slowOutput)
        }
        try await waitFor(URL(fileURLWithPath: slowOutput.path + ".started"))
        do {
            _ = try await service.scan(configuration: configuration, script: script,
                                       settings: ScanSettings(), output: output)
            throw TestFailure(message: "Concurrent scan was accepted")
        } catch let error as ScanFailure {
            try require(error.message == "Skanowanie już trwa.", "Wrong concurrent-scan failure")
        }
        print("PASS: overlapping process rejected")
        service.cancel()
        do {
            _ = try await first.value
            throw TestFailure(message: "Cancellation was not propagated")
        } catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: slowOutput.path),
                    "Cancelled fixture unexpectedly published an output")
        print("PASS: cancellation terminates child and reaches caller")

        var lateSettings = ScanSettings()
        lateSettings.paper = "LateSuccess"
        let lateOutput = temporary.appendingPathComponent("committed.png")
        let committed = Task { @MainActor in
            try await service.scan(configuration: configuration, script: script,
                                   settings: lateSettings, output: lateOutput)
        }
        try await waitFor(URL(fileURLWithPath: lateOutput.path + ".published"))
        service.cancel()
        let completed: ScanResult
        do {
            completed = try await committed.value
        } catch is CancellationError {
            throw TestFailure(message: "Late cancellation hid the successfully published scan")
        }
        try require(completed.path == lateOutput.path && FileManager.default.fileExists(atPath: completed.path),
                    "Committed output was not preserved and returned")
        print("PASS: published success wins over a late cancellation request")
    }

    @MainActor
    static func main() async {
        do {
            try await runTests()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
