import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

@MainActor
enum ComputerUse {
    static let supportedKeys: Set<String> = [
        "return", "tab", "escape", "backspace", "delete", "space",
        "up", "down", "left", "right", "home", "end", "page_up", "page_down",
        "cmd+a", "cmd+c", "cmd+v", "cmd+z", "cmd+s", "cmd+w", "cmd+q"
    ]

    static func inspectScreen() async throws -> String {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ComputerUseError("Grant Agent Chats access in System Settings > Privacy & Security > Screen Recording, then ask me to inspect the screen again.")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ComputerUseError("No screen is available to inspect.")
            }

            let ownApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApp.map { [$0] } ?? [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = min(display.width, 1_280)
            configuration.height = max(1, Int(Double(configuration.width) * Double(display.height) / Double(display.width)))
            configuration.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])

            let observations = (request.results ?? []).sorted { left, right in
                let leftY = 1 - left.boundingBox.midY
                let rightY = 1 - right.boundingBox.midY
                if abs(leftY - rightY) > 0.015 { return leftY < rightY }
                return left.boundingBox.minX < right.boundingBox.minX
            }
            let lines = observations.compactMap { observation -> String? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let x = Int((observation.boundingBox.midX * 1_000).rounded())
                let y = Int(((1 - observation.boundingBox.midY) * 1_000).rounded())
                return "[x=\(x), y=\(y)] \(text)"
            }
            let output = lines.isEmpty ? "No readable text found on the main display." : lines.prefix(100).joined(separator: "\n")
            return "Main display inspected (\(image.width) × \(image.height) pixels). Coordinates use 0–1000, origin at the top-left.\n\(output)"
        } catch let error as ComputerUseError {
            throw error
        } catch {
            throw ComputerUseError("Could not read the screen. Check Screen Recording permission in System Settings > Privacy & Security > Screen Recording. Details: \(error.localizedDescription)")
        }
    }

    static func perform(_ request: PendingComputerAction) throws -> String {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw ComputerUseError("Grant Agent Chats permission in System Settings > Privacy & Security > Accessibility, then ask me to retry the approved action.")
        }

        let shouldRestoreApp = !NSApplication.shared.isHidden
        if shouldRestoreApp {
            NSApplication.shared.hide(nil)
            Thread.sleep(forTimeInterval: 0.12)
        }
        defer {
            if shouldRestoreApp {
                Thread.sleep(forTimeInterval: 0.08)
                NSApplication.shared.unhideWithoutActivation()
            }
        }

        switch request.kind {
        case .click:
            guard let x = request.x, let y = request.y else { throw ComputerUseError("The click position is missing.") }
            postClick(at: screenPoint(x: x, y: y))
            return "Clicked at x=\(x), y=\(y)."
        case .typeText:
            guard let text = request.text else { throw ComputerUseError("The text to type is missing.") }
            postText(text)
            return "Typed the approved text."
        case .pressKey:
            guard let key = request.key else { throw ComputerUseError("The key is missing.") }
            try postKey(key)
            return "Pressed \(key)."
        case .scroll:
            guard let x = request.x, let y = request.y,
                  let direction = request.direction, let amount = request.amount else {
                throw ComputerUseError("The scroll details are incomplete.")
            }
            postScroll(at: screenPoint(x: x, y: y), direction: direction, amount: amount)
            return "Scrolled \(direction) by \(amount) lines."
        }
    }

    private static func screenPoint(x: Int, y: Int) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.minX + bounds.width * CGFloat(x) / 1_000,
            y: bounds.minY + bounds.height * CGFloat(y) / 1_000
        )
    }

    private static func postClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func postText(_ text: String) {
        var chunk = ""
        var utf16Count = 0
        for scalar in text.unicodeScalars {
            let piece = String(scalar)
            let count = piece.utf16.count
            if utf16Count + count > 20 {
                postUnicodeChunk(chunk)
                chunk = ""
                utf16Count = 0
            }
            chunk.append(piece)
            utf16Count += count
        }
        if !chunk.isEmpty { postUnicodeChunk(chunk) }
    }

    private static func postUnicodeChunk(_ text: String) {
        let units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postKey(_ key: String) throws {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        switch key {
        case "return": (keyCode, flags) = (36, [])
        case "tab": (keyCode, flags) = (48, [])
        case "escape": (keyCode, flags) = (53, [])
        case "backspace": (keyCode, flags) = (51, [])
        case "delete": (keyCode, flags) = (117, [])
        case "space": (keyCode, flags) = (49, [])
        case "up": (keyCode, flags) = (126, [])
        case "down": (keyCode, flags) = (125, [])
        case "left": (keyCode, flags) = (123, [])
        case "right": (keyCode, flags) = (124, [])
        case "home": (keyCode, flags) = (115, [])
        case "end": (keyCode, flags) = (119, [])
        case "page_up": (keyCode, flags) = (116, [])
        case "page_down": (keyCode, flags) = (121, [])
        case "cmd+a": (keyCode, flags) = (0, .maskCommand)
        case "cmd+c": (keyCode, flags) = (8, .maskCommand)
        case "cmd+v": (keyCode, flags) = (9, .maskCommand)
        case "cmd+z": (keyCode, flags) = (6, .maskCommand)
        case "cmd+s": (keyCode, flags) = (1, .maskCommand)
        case "cmd+w": (keyCode, flags) = (13, .maskCommand)
        case "cmd+q": (keyCode, flags) = (12, .maskCommand)
        default: throw ComputerUseError("Unsupported key: \(key).")
        }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw ComputerUseError("macOS could not create the key event.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postScroll(at point: CGPoint, direction: String, amount: Int) {
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        let delta = Int32(amount * (direction == "up" ? 1 : -1))
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }
}

private struct ComputerUseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}
