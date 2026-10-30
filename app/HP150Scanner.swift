import AppKit
import SwiftUI

@MainActor
final class ScannerAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ScannerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isScanning else { return .terminateNow }
        model.onIdle = { sender.reply(toApplicationShouldTerminate: true) }
        model.cancel()
        return .terminateLater
    }
}

@main
struct HP150ScannerApp: App {
    @NSApplicationDelegateAdaptor(ScannerAppDelegate.self) private var appDelegate
    @StateObject private var model = ScannerModel()

    var body: some Scene {
        Window("HP150 Scanner", id: "scanner") {
            ContentView(model: model).onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Skanuj…", action: model.chooseDestinationAndScan)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(model.isBusy)
            }
        }
    }
}
