#!/usr/bin/env swift
// Read-only discovery of local scanners exposed by macOS Image Capture.
// Run: xcrun swift scripts/discover-scanners.swift
// This does not open a scanner session, acquire an image, or prove scanning works.
import Foundation
import ImageCaptureCore

final class ScannerDiscovery: NSObject, ICDeviceBrowserDelegate {
    var localEnumerationCompleted = false

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                       moreComing: Bool) {}

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice,
                       moreGoing: Bool) {}

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        localEnumerationCompleted = true
    }
}

struct Scanner: Encodable {
    let name: String?
    let transport: String?
    let usbVendorID: Int32
    let usbProductID: Int32
}

struct DiscoveryReport: Encodable {
    let schemaVersion = 1
    let scope = "local"
    let discoverySeconds: Double
    let localEnumerationCompleted: Bool
    let scanners: [Scanner]
}

let duration: TimeInterval = 8
let discovery = ScannerDiscovery()
let browser = ICDeviceBrowser()
browser.delegate = discovery
// Apple's ICDeviceBrowser.h specifies OR'ing the device and location masks.
browser.browsedDeviceTypeMask = ICDeviceTypeMask(
    rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
)!
browser.start()
RunLoop.current.run(until: Date(timeIntervalSinceNow: duration))

let scanners = (browser.devices ?? []).compactMap { device -> Scanner? in
    guard device is ICScannerDevice else { return nil }
    return Scanner(name: device.name, transport: device.transportType,
                   usbVendorID: device.usbVendorID, usbProductID: device.usbProductID)
}.sorted { ($0.name ?? "") < ($1.name ?? "") }
let report = DiscoveryReport(discoverySeconds: duration,
                             localEnumerationCompleted: discovery.localEnumerationCompleted,
                             scanners: scanners)
browser.stop()

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Cannot encode scanner discovery: \(error)\n".utf8))
    exit(1)
}
