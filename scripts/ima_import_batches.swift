#!/usr/bin/env swift
import ApplicationServices
import AppKit
import Foundation
import ImageIO

let appBundleID = "com.tencent.imamac"
var cachedImaAxApp: AXUIElement?
var cachedMainFrame: CGRect?

struct Options {
    var exportDir = URL(fileURLWithPath: "tmp/wechat_favorites_export")
    var batchDir: URL?
    var fromBatch = 1
    var toBatch = 1
    var batchSize = 10
    var delay: useconds_t = 220_000
    var dialogTimeout: Double = 5
    var submitTimeout: Double = 20
    var verbose = false
    var resolveInflight: String?
    var recoverOnly = false
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--dir":
            guard let value = args.first else { fatalError("--dir requires a value") }
            args.removeFirst()
            options.exportDir = URL(fileURLWithPath: value)
        case "--batch-dir":
            guard let value = args.first else { fatalError("--batch-dir requires a value") }
            args.removeFirst()
            options.batchDir = URL(fileURLWithPath: value)
        case "--from":
            guard let value = args.first, let intValue = Int(value) else { fatalError("--from requires an integer") }
            args.removeFirst()
            options.fromBatch = intValue
        case "--to":
            guard let value = args.first, let intValue = Int(value) else { fatalError("--to requires an integer") }
            args.removeFirst()
            options.toBatch = intValue
        case "--batch-size":
            guard let value = args.first, let intValue = Int(value) else { fatalError("--batch-size requires an integer") }
            args.removeFirst()
            options.batchSize = intValue
        case "--delay-ms":
            guard let value = args.first, let intValue = Int(value) else { fatalError("--delay-ms requires an integer") }
            args.removeFirst()
            options.delay = useconds_t(max(40, intValue) * 1000)
        case "--dialog-timeout":
            guard let value = args.first, let doubleValue = Double(value) else { fatalError("--dialog-timeout requires a number") }
            args.removeFirst()
            options.dialogTimeout = max(1, doubleValue)
        case "--submit-timeout":
            guard let value = args.first, let doubleValue = Double(value) else { fatalError("--submit-timeout requires a number") }
            args.removeFirst()
            options.submitTimeout = max(3, doubleValue)
        case "--fast":
            options.delay = 90_000
            options.dialogTimeout = 3
            options.submitTimeout = 12
        case "--turbo":
            options.delay = 55_000
            options.dialogTimeout = 2.5
            options.submitTimeout = 9
        case "--verbose":
            options.verbose = true
        case "--resolve-inflight":
            guard let value = args.first, ["submitted", "retry"].contains(value) else {
                fatalError("--resolve-inflight requires submitted or retry")
            }
            args.removeFirst()
            options.resolveInflight = value
        case "--recover-only":
            options.recoverOnly = true
        default:
            fatalError("Unknown option: \(arg)")
        }
    }
    return options
}

struct ImportJournal: Codable {
    var version = 1
    var batch: Int
    var batchPath: String
    var lineCount: Int
    var phase: String
    var updatedAt: String
}

func axValue<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

func axCGPoint(_ value: AXValue?) -> CGPoint? {
    guard let value else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func axCGSize(_ value: AXValue?) -> CGSize? {
    guard let value else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute, as: [AXUIElement].self) ?? []
}

func allDescendants(of element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var stack = children(of: element)
    while let next = stack.popLast() {
        result.append(next)
        stack.append(contentsOf: children(of: next))
    }
    return result
}

func role(of element: AXUIElement) -> String {
    axValue(element, kAXRoleAttribute, as: String.self) ?? ""
}

func text(of element: AXUIElement) -> String {
    axValue(element, kAXTitleAttribute, as: String.self)
        ?? axValue(element, kAXValueAttribute, as: String.self)
        ?? axValue(element, kAXDescriptionAttribute, as: String.self)
        ?? ""
}

func placeholder(of element: AXUIElement) -> String {
    axValue(element, kAXPlaceholderValueAttribute, as: String.self) ?? ""
}

func frame(of element: AXUIElement) -> CGRect? {
    guard
        let position = axCGPoint(axValue(element, kAXPositionAttribute, as: AXValue.self)),
        let size = axCGSize(axValue(element, kAXSizeAttribute, as: AXValue.self))
    else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

func click(_ point: CGPoint, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
}

func clickCenter(of element: AXUIElement) -> Bool {
    guard let rect = frame(of: element), rect.width > 0, rect.height > 0 else { return false }
    click(CGPoint(x: rect.midX, y: rect.midY))
    return true
}

func press(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<4 {
        guard let target = current else { break }
        if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
            return true
        }
        current = axValue(target, kAXParentAttribute, as: AXUIElement.self)
    }
    return clickCenter(of: element)
}

func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(40_000)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

func pasteFromClipboard() {
    key(9, flags: .maskCommand)
}

func setClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func replaceText(_ text: String, in element: AXUIElement, delay: useconds_t) -> Bool {
    let directResult = AXUIElementSetAttributeValue(
        element,
        kAXValueAttribute as CFString,
        text as CFString
    )
    if directResult == .success {
        let current = axValue(element, kAXValueAttribute, as: String.self) ?? ""
        if current.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return true
        }
    }

    guard clickCenter(of: element) else { return false }
    usleep(min(delay, 80_000))
    key(0, flags: .maskCommand)
    setClipboard(text)
    pasteFromClipboard()
    return true
}

func runningIma() -> NSRunningApplication {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first else {
        fatalError("ima.copilot is not running")
    }
    return app
}

func axApp(for app: NSRunningApplication) -> AXUIElement {
    AXUIElementCreateApplication(app.processIdentifier)
}

func windows(in axApp: AXUIElement) -> [AXUIElement] {
    axValue(axApp, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
}

func mainWindow(in axApp: AXUIElement) -> AXUIElement? {
    let candidates = windows(in: axApp)
    if let named = candidates.first(where: { text(of: $0).contains("微信收藏夹") }) {
        return named
    }
    return candidates.first
}

func freshAxApp() -> AXUIElement {
    if let cachedImaAxApp { return cachedImaAxApp }
    let element = axApp(for: runningIma())
    cachedImaAxApp = element
    return element
}

func activateMainWindowRect() -> CGRect? {
    let app = runningIma()
    app.activate()
    _ = waitUntil(timeoutSeconds: 0.8, interval: 20_000) { app.isActive }
    let axApp = freshAxApp()
    guard let window = mainWindow(in: axApp) else {
        return cachedMainFrame
    }
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    usleep(80_000)
    if let rect = frame(of: window), rect.width > 300, rect.height > 300 {
        cachedMainFrame = rect
        return rect
    }
    return cachedMainFrame
}

func contentAddPoint(in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + min(rect.width - 96, 714), y: rect.minY + 168)
}

func webLinkMenuPoint(in rect: CGRect) -> CGPoint {
    let addPoint = contentAddPoint(in: rect)
    return CGPoint(x: addPoint.x + 35, y: addPoint.y + 187)
}

func dialogTextPoint(in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * 0.529, y: rect.minY + 378)
}

func dialogImportPoint(in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * 0.650, y: rect.minY + 514)
}

func captureImage(of rect: CGRect) -> CGImage? {
    let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ima-import-\(UUID().uuidString).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = [
        "-x",
        "-R",
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
        temporaryURL.path,
    ]
    do {
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard
            process.terminationStatus == 0,
            let source = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        return nil
    }
}

func pixelRGBA(in image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
    guard
        x >= 0, y >= 0, x < image.width, y < image.height,
        let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
    else {
        return nil
    }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        return nil
    }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2], pixel[3])
}

func brightness(at point: CGPoint, in image: CGImage, rect: CGRect) -> Double? {
    let scaleX = Double(image.width) / Double(rect.width)
    let scaleY = Double(image.height) / Double(rect.height)
    let x = Int((point.x - rect.minX) * scaleX)
    let y = Int((point.y - rect.minY) * scaleY)
    guard let (red, green, blue, _) = pixelRGBA(in: image, x: x, y: y) else {
        return nil
    }
    return (Double(red) + Double(green) + Double(blue)) / 3.0
}

func importDialogVisible(in rect: CGRect) -> Bool {
    guard let image = captureImage(of: rect) else {
        return false
    }
    let dimmedContentPoint = CGPoint(x: rect.minX + 369, y: rect.minY + 258)
    guard let value = brightness(at: dimmedContentPoint, in: image, rect: rect) else {
        return false
    }
    return value < 245
}

func elements(in axApp: AXUIElement) -> [AXUIElement] {
    windows(in: axApp).flatMap { [$0] + allDescendants(of: $0) }
}

func findTextArea(in axApp: AXUIElement) -> AXUIElement? {
    elements(in: axApp).first { element in
        let r = role(of: element)
        guard r == (kAXTextAreaRole as String) || r == (kAXTextFieldRole as String) else { return false }
        let p = placeholder(of: element)
        return p.contains("粘贴或输入链接") || text(of: element).contains("粘贴或输入链接")
    }
}

func findExactText(_ value: String, in axApp: AXUIElement) -> AXUIElement? {
    elements(in: axApp)
        .filter { text(of: $0) == value }
        .sorted { lhs, rhs in
            let left = frame(of: lhs) ?? .zero
            let right = frame(of: rhs) ?? .zero
            return left.maxY > right.maxY
        }
        .first
}

func waitUntil(timeoutSeconds: Double, interval: useconds_t = 150_000, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(interval)
    }
    return condition()
}

func openImportDialog(axApp: AXUIElement, options: Options) -> Bool {
    guard let rect = activateMainWindowRect() else {
        return false
    }

    if importDialogVisible(in: rect) {
        return true
    }

    click(contentAddPoint(in: rect))
    usleep(options.delay)

    click(webLinkMenuPoint(in: rect))
    return waitUntil(timeoutSeconds: options.dialogTimeout, interval: 80_000) {
        importDialogVisible(in: rect)
    }
}

func prepareBatch(text batchText: String, options: Options) -> Bool {
    guard openImportDialog(axApp: freshAxApp(), options: options) else {
        fputs("failed: import dialog not found\n", stderr)
        return false
    }
    guard let rect = activateMainWindowRect() else {
        fputs("failed: ima window not found\n", stderr)
        return false
    }

    setClipboard(batchText)
    click(dialogTextPoint(in: rect))
    usleep(min(options.delay, 80_000))
    pasteFromClipboard()
    usleep(options.delay)
    return true
}

func submitPreparedBatch(options: Options, willSubmit: () throws -> Void) throws -> Bool {
    guard let rect = activateMainWindowRect() else {
        fputs("failed: ima window not found\n", stderr)
        return false
    }
    let importPoint = dialogImportPoint(in: rect)
    guard importDialogVisible(in: rect) else {
        fputs("failed: import button not found\n", stderr)
        return false
    }

    try willSubmit()
    click(importPoint)

    return waitUntil(timeoutSeconds: options.submitTimeout, interval: 180_000) {
        !importDialogVisible(in: rect)
    }
}

func markImported(exportDir: URL, batchURL: URL) throws -> (imported: Int?, pending: Int?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "scripts/wechat_favorites_progress.py",
        "--dir", exportDir.path,
        "mark-imported", batchURL.path,
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let output = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "ima_import_batches", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
    }
    guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return (nil, nil)
    }
    return (json["imported_count"] as? Int, json["pending_count"] as? Int)
}

func linkLines(in text: String) -> [String] {
    text
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func importedLinks(in exportDir: URL) -> Set<String> {
    let url = exportDir.appendingPathComponent("imported_links.txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return Set(linkLines(in: text))
}

func writeJournal(_ journal: ImportJournal, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(journal)
    try data.write(to: url, options: .atomic)
}

func loadJournal(from url: URL) -> ImportJournal? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ImportJournal.self, from: data)
}

func removeJournal(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

func journal(batch: Int, batchURL: URL, count: Int, phase: String) -> ImportJournal {
    ImportJournal(
        batch: batch,
        batchPath: batchURL.path,
        lineCount: count,
        phase: phase,
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
}

let options = parseOptions()
let journalURL = options.exportDir.appendingPathComponent("import_inflight.json")
let batchDir = options.batchDir ?? options.exportDir.appendingPathComponent("batches")

if let inflight = loadJournal(from: journalURL) {
    let batchURL = URL(fileURLWithPath: inflight.batchPath)
    if inflight.phase == "confirmed" || options.resolveInflight == "submitted" {
        _ = try markImported(exportDir: options.exportDir, batchURL: batchURL)
        removeJournal(at: journalURL)
        print("recovered batch=\(inflight.batch) as_submitted=true")
    } else if inflight.phase == "prepared" || options.resolveInflight == "retry" {
        removeJournal(at: journalURL)
        print("recovered batch=\(inflight.batch) retry=true")
    } else {
        fatalError("batch \(inflight.batch) has an uncertain prior submission; rerun with --resolve-inflight submitted after confirming it appears in ima, or --resolve-inflight retry")
    }
}

if options.recoverOnly {
    exit(0)
}

let app = runningIma()
app.activate()
_ = waitUntil(timeoutSeconds: 0.5, interval: 20_000) { app.isActive }

for batch in options.fromBatch...options.toBatch {
    let batchURL = batchDir
        .appendingPathComponent(String(format: "batch_%03d.txt", batch))
    let batchText = try String(contentsOf: batchURL, encoding: .utf8)
    let allLines = linkLines(in: batchText)
    if allLines.isEmpty {
        print("batch=\(batch) skipped lines=0")
        continue
    }
    if allLines.count > options.batchSize {
        fatalError("batch \(batch) has \(allLines.count) links; limit is \(options.batchSize)")
    }
    let importedBeforeBatch = importedLinks(in: options.exportDir)
    let pendingLines = allLines.filter { !importedBeforeBatch.contains($0) }
    if pendingLines.isEmpty {
        print("batch=\(batch) skipped already_imported=true lines=\(allLines.count)")
        continue
    }

    let payload = pendingLines.joined(separator: "\n") + "\n"
    try writeJournal(journal(batch: batch, batchURL: batchURL, count: pendingLines.count, phase: "prepared"), to: journalURL)
    guard prepareBatch(text: payload, options: options) else {
        fatalError("batch \(batch) was not submitted")
    }
    guard try submitPreparedBatch(options: options, willSubmit: {
        try writeJournal(journal(batch: batch, batchURL: batchURL, count: pendingLines.count, phase: "submitting"), to: journalURL)
    }) else {
        fatalError("batch \(batch) submission could not be confirmed")
    }
    try writeJournal(journal(batch: batch, batchURL: batchURL, count: pendingLines.count, phase: "confirmed"), to: journalURL)

    let progress = try markImported(exportDir: options.exportDir, batchURL: batchURL)
    removeJournal(at: journalURL)
    let imported = progress.imported.map(String.init) ?? "unknown"
    let pending = progress.pending.map(String.init) ?? "unknown"
    print("batch=\(batch) submitted lines=\(pendingLines.count) imported=\(imported) pending=\(pending)")
}
