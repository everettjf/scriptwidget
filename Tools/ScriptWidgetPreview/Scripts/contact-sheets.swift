// Builds the contact sheets of Resource/WidgetDemoScreenshots from the
// pictures in that folder: 20 templates a sheet, 5 across, name below.
//
//   swift Tools/ScriptWidgetPreview/Scripts/contact-sheets.swift Resource/WidgetDemoScreenshots
//
// The pictures themselves come from the Mac app:
//   ScriptWidget.app/Contents/MacOS/ScriptWidget --render-template-previews <folder>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: contact-sheets.swift <folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

for old in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
where old.lastPathComponent.hasPrefix("_contact-sheet-") {
    try FileManager.default.removeItem(at: old)
}

let columns = 5, rows = 4
let cellWidth = 380, cellHeight = 390, picture = 338
let width = columns * cellWidth, height = rows * cellHeight
let background = CGColor(red: 0.094, green: 0.094, blue: 0.106, alpha: 1)

var sheet = 0
for start in stride(from: 0, to: files.count, by: columns * rows) {
    sheet += 1
    let page = Array(files[start..<min(start + columns * rows, files.count)])
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { exit(1) }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    for (index, file) in page.enumerated() {
        guard let source = NSImage(contentsOf: file),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let column = index % columns, row = index / columns
        let scale = min(CGFloat(picture) / CGFloat(image.width), CGFloat(picture) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let left = CGFloat(column * cellWidth)
        let top = CGFloat(height - row * cellHeight)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: left, y: top - drawn.height, width: drawn.width, height: drawn.height))
        let name = file.deletingPathExtension().lastPathComponent as NSString
        name.draw(
            at: CGPoint(x: left, y: top - CGFloat(picture) - 28),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white]
        )
    }

    guard let result = context.makeImage() else { exit(1) }
    let data = NSBitmapImageRep(cgImage: result)
        .representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
    try data.write(to: folder.appendingPathComponent("_contact-sheet-\(sheet).jpg"))
}
print("\(files.count) pictures on \(sheet) sheets")
