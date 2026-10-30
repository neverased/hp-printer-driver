import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class ScannerModel: ObservableObject {
    @Published var settings = ScanSettings()
    @Published private(set) var isScanning = false
    @Published private(set) var isChoosingDestination = false
    @Published private(set) var isCancelling = false
    @Published private(set) var result: ScanResult?
    @Published private(set) var failure: ScanFailure?
    @Published private(set) var notice: String?
    var onIdle: (() -> Void)?
    private let scanner = ScannerProcess()
    var isBusy: Bool { isScanning || isChoosingDestination }

    func chooseDestinationAndScan() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Zapisz skan"
        panel.prompt = "Skanuj"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Skan-\(formatter.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        isChoosingDestination = true
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isChoosingDestination = false
            guard response == .OK, let output = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                self.failure = ScanFailure(message: "Plik już istnieje. Wybierz inną nazwę.", details: nil)
                return
            }
            self.start(output: output)
        }
    }

    func cancel() {
        guard isScanning, !isCancelling else { return }
        isCancelling = true
        scanner.cancel()
    }

    private func start(output: URL) {
        guard !isScanning else { return }
        isScanning = true
        isCancelling = false
        result = nil
        failure = nil
        notice = nil
        let selectedSettings = settings
        Task {
            defer {
                isScanning = false
                isCancelling = false
                onIdle?()
            }
            do {
                guard !isCancelling else { throw CancellationError() }
                let configuration = try ScannerConfiguration.load()
                guard let script = Bundle.main.url(forResource: "scan-native", withExtension: "py") else {
                    throw ScanFailure(message: "Brakuje programu obsługującego skaner.", details: nil)
                }
                result = try await scanner.scan(configuration: configuration, script: script,
                                                settings: selectedSettings, output: output)
            } catch is CancellationError {
                notice = "Anulowano skanowanie. Przed następną próbą włóż kartkę ponownie."
            } catch let error as ScanFailure {
                failure = error
            } catch {
                failure = ScanFailure(message: "Nie udało się uruchomić skanowania.",
                                      details: error.localizedDescription)
            }
        }
    }

    func openResult() {
        guard let result else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
    }

    func revealResult() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
    }
}
