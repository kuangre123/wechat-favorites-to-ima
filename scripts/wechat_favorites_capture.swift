#!/usr/bin/env swift
import ApplicationServices
import AppKit
import Foundation

let appBundleId = "com.tencent.xinWeChat"
let linkPattern = #"https?://mp\.weixin\.qq\.com/s(?:/[A-Za-z0-9_-]+|\?[^\s]+)"#
let linkPrefix = "https://mp.weixin.qq.com/s"

struct Options {
    var exportDir = URL(fileURLWithPath: "tmp/wechat_favorites_export")
    var target = 100
    var maxPages = 60
    var delay: useconds_t = 120_000
    var menuTimeout: useconds_t = 360_000
    var clipboardTimeout: useconds_t = 360_000
    var stalePageLimit = 6
    var scrollPixels: Int32 = -620
    var dryRun = false
    var verbose = false
    var useCliclick = true
    var rememberRows = true
    var rowDX: CGFloat? = 256
    var menuDX: CGFloat = 90
    var menuDY: CGFloat = 48
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--dir":
            if let value = args.first {
                args.removeFirst()
                options.exportDir = URL(fileURLWithPath: value)
            }
        case "--target":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.target = intValue
            }
        case "--max-pages":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.maxPages = intValue
            }
        case "--delay-ms":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.delay = useconds_t(max(10, intValue) * 1000)
            }
        case "--menu-timeout-ms":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.menuTimeout = useconds_t(max(30, intValue) * 1000)
            }
        case "--clipboard-timeout-ms":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.clipboardTimeout = useconds_t(max(30, intValue) * 1000)
            }
        case "--stale-pages":
            if let value = args.first, let intValue = Int(value) {
                args.removeFirst()
                options.stalePageLimit = max(1, intValue)
            }
        case "--scroll-pixels":
            if let value = args.first, let intValue = Int32(value) {
                args.removeFirst()
                options.scrollPixels = intValue
            }
        case "--fast":
            options.delay = 70_000
            options.menuTimeout = 240_000
            options.clipboardTimeout = 240_000
            options.scrollPixels = -720
            options.useCliclick = false
        case "--turbo":
            options.delay = 45_000
            options.menuTimeout = 170_000
            options.clipboardTimeout = 190_000
            options.scrollPixels = -780
            options.useCliclick = false
        case "--dry-run":
            options.dryRun = true
        case "--verbose":
            options.verbose = true
        case "--cg-event":
            options.useCliclick = false
        case "--cliclick":
            options.useCliclick = true
        case "--no-row-progress":
            options.rememberRows = false
        case "--menu-dx":
            if let value = args.first, let doubleValue = Double(value) {
                args.removeFirst()
                options.menuDX = CGFloat(doubleValue)
            }
        case "--menu-dy":
            if let value = args.first, let doubleValue = Double(value) {
                args.removeFirst()
                options.menuDY = CGFloat(doubleValue)
            }
        case "--row-dx":
            if let value = args.first, let doubleValue = Double(value) {
                args.removeFirst()
                options.rowDX = CGFloat(doubleValue)
            }
        default:
            fputs("Unknown option: \(arg)\n", stderr)
            exit(2)
        }
    }
    return options
}

struct CaptureState: Codable {
    var version = 1
    var processedRowFingerprints: [String] = []
    var updatedAt = ""
}

enum CopyResult {
    case link(String)
    case nonWeChat
    case failed
}

func axValue<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) -> T? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if result != .success {
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

func title(of element: AXUIElement) -> String {
    axValue(element, kAXTitleAttribute, as: String.self)
        ?? axValue(element, kAXValueAttribute, as: String.self)
        ?? ""
}

func frame(of element: AXUIElement) -> CGRect? {
    let position = axCGPoint(axValue(element, kAXPositionAttribute, as: AXValue.self))
    let size = axCGSize(axValue(element, kAXSizeAttribute, as: AXValue.self))
    guard let position, let size else { return nil }
    return CGRect(origin: position, size: size)
}

func runningWeChat() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).first
}

func hideNoisyApps() {
    for bundleID in ["com.openai.codex", "com.google.Chrome"] {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.hide()
        }
    }
}

@discardableResult
func runAppleScript(_ source: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func frontmostProcessName() -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"System Events\" to name of first application process whose frontmost is true"]
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return ""
    }
}

func waitForActivation(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if app.isActive { return true }
        usleep(20_000)
    }
    return app.isActive
}

func forceActivateWeChat(_ app: NSRunningApplication) {
    app.activate()
    if waitForActivation(app, timeout: 0.18) { return }

    hideNoisyApps()
    runAppleScript("tell application id \"com.tencent.xinWeChat\" to activate")
    _ = waitForActivation(app, timeout: 0.5)
}

func mainWindow(in axApp: AXUIElement) -> AXUIElement? {
    let windows = axValue(axApp, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    let ranked = windows.map { window in
        (window: window, rowCount: visibleFavoriteRows(in: window).count)
    }
    if let favoriteWindow = ranked.max(by: { $0.rowCount < $1.rowCount }), favoriteWindow.rowCount > 0 {
        AXUIElementPerformAction(favoriteWindow.window, kAXRaiseAction as CFString)
        return favoriteWindow.window
    }
    return windows.first
}

func visibleFavoriteRows(in window: AXUIElement) -> [(String, CGRect)] {
    allDescendants(of: window)
        .filter { role(of: $0) == kAXStaticTextRole as String }
        .compactMap { element -> (String, CGRect)? in
            let text = title(of: element)
            guard text.hasPrefix("链接") else { return nil }
            guard let rect = frame(of: element), rect.width > 100, rect.height > 20 else { return nil }
            guard rect.minY >= 140 else { return nil }
            guard text.count > 5 else { return nil }
            return (text, rect)
        }
        .sorted { lhs, rhs in
            if abs(lhs.1.minY - rhs.1.minY) > 4 {
                return lhs.1.minY < rhs.1.minY
            }
            return lhs.1.minX < rhs.1.minX
        }
}

func click(_ point: CGPoint, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
}

func keyEscape() {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
}

@discardableResult
func runCliclick(_ args: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cliclick")
    process.arguments = args
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func scroll(at point: CGPoint, dy: Int32) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
}

func clipboardText() -> String {
    NSPasteboard.general.string(forType: .string) ?? ""
}

func setClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func extractLinks(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: linkPattern) else { return [] }
    let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: nsrange).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        return cleanLink(String(text[range]))
    }
}

func cleanLink(_ value: String) -> String {
    var link = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if link.hasPrefix("http://mp.weixin.qq.com/s") {
        link = "https://" + String(link.dropFirst("http://".count))
    }
    if let duplicateRange = link.range(of: linkPrefix, options: [], range: link.index(link.startIndex, offsetBy: min(linkPrefix.count, link.count))..<link.endIndex) {
        link = String(link[..<duplicateRange.lowerBound])
    }
    if link.hasSuffix("https") {
        link = String(link.dropLast(5))
    }
    return link
}

func urlHosts(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) else { return [] }
    let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: nsrange).prefix(5).compactMap { match in
        guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])) else {
            return nil
        }
        return url.host
    }
}

func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 1
        && abs(lhs.minY - rhs.minY) < 1
        && abs(lhs.width - rhs.width) < 1
        && abs(lhs.height - rhs.height) < 1
}

func contextMenuFrame(in axApp: AXUIElement, excluding baseline: [CGRect], near point: CGPoint) -> CGRect? {
    let candidates = smallWeChatWindows(in: axApp)
    let added = candidates.filter { candidate in
        !baseline.contains(where: { sameFrame(candidate, $0) })
    }
    return added.min { lhs, rhs in
            let lhsDistance = hypot(lhs.midX - point.x, lhs.midY - point.y)
            let rhsDistance = hypot(rhs.midX - point.x, rhs.midY - point.y)
            return lhsDistance < rhsDistance
        }
}

func waitUntil(timeout: useconds_t, interval: useconds_t = 15_000, _ condition: () -> Bool) -> Bool {
    let started = Date()
    let seconds = Double(timeout) / 1_000_000
    while Date().timeIntervalSince(started) < seconds {
        if condition() {
            return true
        }
        usleep(interval)
    }
    return condition()
}

func smallWeChatWindows(in axApp: AXUIElement) -> [CGRect] {
    let windows = axValue(axApp, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    return windows
        .compactMap(frame(of:))
        .filter { $0.width >= 80 && $0.width <= 420 && $0.height >= 30 && $0.height <= 460 }
        .sorted {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
}

func loadLinks(_ url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return extractLinks(text)
}

func appendLink(_ link: String, to url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    if let data = "\(link)\n".data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

func rowFingerprint(_ text: String) -> String {
    let normalized = text
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in normalized.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

func contextualRowFingerprints(_ rows: [(String, CGRect)]) -> [String] {
    let base = rows.map { rowFingerprint($0.0) }
    return base.indices.map { index in
        let previous = index > base.startIndex ? base[base.index(before: index)] : "^"
        let next = index < base.index(before: base.endIndex) ? base[base.index(after: index)] : "$"
        return rowFingerprint("\(previous)|\(base[index])|\(next)")
    }
}

func loadCaptureState(_ url: URL) -> CaptureState {
    guard
        let data = try? Data(contentsOf: url),
        let state = try? JSONDecoder().decode(CaptureState.self, from: data),
        state.version == 1
    else {
        return CaptureState()
    }
    return state
}

func saveCaptureState(_ state: CaptureState, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    try? data.write(to: url, options: .atomic)
}

func postClick(_ point: CGPoint, button: CGMouseButton, useCliclick: Bool) -> Bool {
    if useCliclick {
        let prefix = button == .right ? "rc" : "c"
        return runCliclick(["\(prefix):\(Int(point.x)),\(Int(point.y))"])
    }
    click(point, button: button)
    return true
}

func copyLink(from row: CGRect, axApp: AXUIElement, options: Options, useCliclick: inout Bool) -> CopyResult {
    let rowPoint = CGPoint(x: options.rowDX.map { row.minX + $0 } ?? row.midX, y: row.midY)
    var menuPoint = CGPoint(x: rowPoint.x + options.menuDX, y: rowPoint.y + options.menuDY)
    if options.verbose || options.dryRun {
        print("row=\(Int(row.minX)),\(Int(row.minY)),\(Int(row.width)),\(Int(row.height)) right=\(Int(rowPoint.x)),\(Int(rowPoint.y)) menu=\(Int(menuPoint.x)),\(Int(menuPoint.y))")
    }
    if options.dryRun {
        return .failed
    }
    if options.verbose {
        print("frontmost=\(frontmostProcessName())")
    }
    let pasteboard = NSPasteboard.general
    let initialChangeCount = pasteboard.changeCount
    let baselineWindows = smallWeChatWindows(in: axApp)

    var backendUsesCliclick = useCliclick
    _ = postClick(rowPoint, button: .right, useCliclick: backendUsesCliclick)
    var detectedMenu: CGRect?
    _ = waitUntil(timeout: options.menuTimeout) {
        detectedMenu = contextMenuFrame(in: axApp, excluding: baselineWindows, near: rowPoint)
        return detectedMenu != nil
    }
    if detectedMenu == nil && !backendUsesCliclick {
        keyEscape()
        backendUsesCliclick = true
        useCliclick = true
        _ = postClick(rowPoint, button: .right, useCliclick: true)
        _ = waitUntil(timeout: options.menuTimeout) {
            detectedMenu = contextMenuFrame(in: axApp, excluding: baselineWindows, near: rowPoint)
            return detectedMenu != nil
        }
    }
    guard let menuRect = detectedMenu else {
        if options.verbose {
            let rects = smallWeChatWindows(in: axApp).map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
            print("menu_window=missing small_windows=\(rects)")
        }
        return .failed
    }
    menuPoint = CGPoint(x: menuRect.minX + options.menuDX, y: menuRect.minY + options.menuDY)
    if options.verbose {
        print("menu_window=\(Int(menuRect.minX)),\(Int(menuRect.minY)),\(Int(menuRect.width)),\(Int(menuRect.height)) click=\(Int(menuPoint.x)),\(Int(menuPoint.y))")
    }
    _ = postClick(menuPoint, button: .left, useCliclick: backendUsesCliclick)

    let clipboardChanged = waitUntil(timeout: options.clipboardTimeout, interval: 10_000) {
        pasteboard.changeCount != initialChangeCount
    }
    guard clipboardChanged else { return .failed }
    let text = clipboardText()
    let links = extractLinks(text)
    if options.verbose {
        print("clipboard len=\(text.count) changed=true hosts=\(urlHosts(text))")
    }
    if let link = links.first {
        return .link(link)
    }
    return .nonWeChat
}

let options = parseOptions()
try? FileManager.default.createDirectory(at: options.exportDir, withIntermediateDirectories: true)
let rawURL = options.exportDir.appendingPathComponent("links_full_raw.txt")
let importedURL = options.exportDir.appendingPathComponent("imported_links.txt")
let captureStateURL = options.exportDir.appendingPathComponent("capture_state.json")

var seen = Set(loadLinks(rawURL) + loadLinks(importedURL))
var capturedThisRun = 0
var skippedProcessedRows = 0
var stalePages = 0
var lastPageSignature = ""
var captureState = options.rememberRows ? loadCaptureState(captureStateURL) : CaptureState()
var processedRows = Set(captureState.processedRowFingerprints)
var useCliclick = options.useCliclick

if seen.count >= options.target {
    print("done captured_this_run=0 skipped_processed_rows=0 total_unique=\(seen.count)")
    exit(0)
}

guard let app = runningWeChat() else {
    fputs("NO_WECHAT\n", stderr)
    exit(1)
}
forceActivateWeChat(app)
let appElement = AXUIElementCreateApplication(app.processIdentifier)

guard var window = mainWindow(in: appElement) else {
    fputs("NO_WINDOW\n", stderr)
    exit(1)
}

for page in 1...options.maxPages {
    var rows = visibleFavoriteRows(in: window)
    if rows.isEmpty, let refreshedWindow = mainWindow(in: appElement) {
        window = refreshedWindow
        rows = visibleFavoriteRows(in: window)
    }

    let baseRowFingerprints = rows.map { rowFingerprint($0.0) }
    let rowFingerprints = contextualRowFingerprints(rows)
    let pageSignature = baseRowFingerprints.joined(separator: ":")
    if rows.isEmpty {
        print("page=\(page) rows=0 total=\(seen.count)")
        stalePages += 1
    } else {
        stalePages = pageSignature == lastPageSignature ? stalePages + 1 : 0
        lastPageSignature = pageSignature
        var stateChanged = false
        for (index, row) in rows.enumerated() {
            if seen.count >= options.target {
                break
            }

            let fingerprint = rowFingerprints[index]
            if options.rememberRows && processedRows.contains(fingerprint) {
                skippedProcessedRows += 1
                continue
            }

            let result = copyLink(from: row.1, axApp: appElement, options: options, useCliclick: &useCliclick)
            switch result {
            case let .link(link):
                if options.rememberRows {
                    processedRows.insert(fingerprint)
                    stateChanged = true
                }
                if !seen.contains(link) {
                    seen.insert(link)
                    appendLink(link, to: rawURL)
                    capturedThisRun += 1
                    print("captured=\(capturedThisRun) total_unique=\(seen.count)")
                } else if options.verbose {
                    print("duplicate total_unique=\(seen.count)")
                }
            case .nonWeChat:
                if options.rememberRows {
                    processedRows.insert(fingerprint)
                    stateChanged = true
                }
                if options.verbose {
                    print("non_wechat total_unique=\(seen.count)")
                }
            case .failed:
                if options.verbose && !options.dryRun {
                print("no_link total_unique=\(seen.count)")
                }
            }
        }
        if stateChanged {
            captureState.processedRowFingerprints = processedRows.sorted()
            captureState.updatedAt = ISO8601DateFormatter().string(from: Date())
            saveCaptureState(captureState, to: captureStateURL)
        }
    }
    if seen.count >= options.target || stalePages >= options.stalePageLimit {
        break
    }
    if let listRect = rows.first?.1 ?? frame(of: window) {
        scroll(at: CGPoint(x: listRect.midX, y: listRect.midY), dy: options.scrollPixels)
    }
    usleep(options.delay)
}

print("done captured_this_run=\(capturedThisRun) skipped_processed_rows=\(skippedProcessedRows) total_unique=\(seen.count)")
