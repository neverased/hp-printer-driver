#!/usr/bin/env swift
// Generate one A4 page for visual verification; never submits a print job.
import Foundation
import CoreGraphics
import CoreText

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: xcrun swift scripts/make-test-page.swift OUTPUT.pdf\n", stderr)
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var page = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else {
    fputs("Cannot create PDF\n", stderr)
    exit(1)
}
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(page)
func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 12) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}
label("HP Officejet 150 - native ARM64 test", x: 42, y: 780, size: 20)
label("A4 / single-sided / color / no scaling", x: 42, y: 753)
label("Check: readable text, separate colors, straight lines, no clipped border.", x: 42, y: 726)
let colors: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("Cyan", 0, 1, 1), ("Magenta", 1, 0, 1), ("Yellow", 1, 1, 0),
    ("Red", 1, 0, 0), ("Green", 0, 1, 0), ("Blue", 0, 0, 1)
]
for (index, entry) in colors.enumerated() {
    let x = CGFloat(index) * 84 + 42
    context.setFillColor(CGColor(red: entry.1, green: entry.2, blue: entry.3, alpha: 1))
    context.fill(CGRect(x: x, y: 606, width: 70, height: 80))
    label(entry.0, x: x, y: 585)
}
for index in 0..<6 {
    context.setFillColor(CGColor(gray: CGFloat(index) / 5, alpha: 1))
    context.fill(CGRect(x: CGFloat(index) * 84 + 42, y: 465, width: 70, height: 80))
}
label("Black and gray ramp", x: 42, y: 444)
for size in [8, 10, 12, 16] {
    label("Text \(size) pt: ABCDEFG abcdefg 0123456789", x: 42, y: CGFloat(390 - (size - 8) * 9), size: CGFloat(size))
}
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineWidth(0.5)
context.stroke(CGRect(x: 42.52, y: 42.52, width: page.width - 85.04, height: page.height - 85.04))
label("Border is 15 mm from each paper edge.", x: 50, y: 65)
context.endPDFPage()
context.closePDF()
print(url.path)
