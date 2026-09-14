#!/usr/bin/env swift
import ApplicationServices
import AppKit
import Foundation

let appBundleID = "com.tencent.imamac"
var cachedImaAxApp: AXUIElement?

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
    if findTextArea(in: axApp) != nil {
        return true
    }
    guard let window = mainWindow(in: axApp), let rect = frame(of: window) else {
        return false
    }

    let uploadPoint = CGPoint(x: rect.maxX - 18, y: rect.minY + 58)
    click(uploadPoint)
    usleep(options.delay)

    let menuAxApp = freshAxApp()
    if let item = findExactText("网页链接", in: menuAxApp), press(item) {
        return waitUntil(timeoutSeconds: options.dialogTimeout, interval: 80_000) {
            findTextArea(in: freshAxApp()) != nil
        }
    }

    let menuFallbackPoint = CGPoint(x: rect.maxX - 126, y: rect.minY + 181)
    click(menuFallbackPoint)
    return waitUntil(timeoutSeconds: options.dialogTimeout, interval: 80_000) {
        findTextArea(in: freshAxApp()) != nil
    }
}

func prepareBatch(text batchText: String, options: Options) -> Bool {
    guard openImportDialog(axApp: freshAxApp(), options: options) else {
        fputs("failed: import dialog not found\n", stderr)
        return false
    }
    guard let area = findTextArea(in: freshAxApp()) else {
        fputs("failed: link text area not found\n", stderr)
        return false
    }

    guard replaceText(batchText, in: area, delay: options.delay) else {
        fputs("failed: could not enter links\n", stderr)
        return false
    }
    usleep(options.delay)
    return true
}

func submitPreparedBatch(options: Options, willSubmit: () throws -> Void) throws -> Bool {
    guard let importButton = findExactText("导入", in: freshAxApp()) else {
        fputs("failed: import button not found\n", stderr)
        return false
    }

    try willSubmit()
    guard press(importButton) else {
        fputs("failed: import button could not be pressed\n", stderr)
        return false
    }

    return waitUntil(timeoutSeconds: options.submitTimeout, interval: 180_000) {
        findTextArea(in: freshAxApp()) == nil
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
