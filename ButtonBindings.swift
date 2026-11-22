import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

struct KeyShortcut {
    enum Modifier: String {
        case cmd, ctrl, opt, shift

        var flag: CGEventFlags {
            switch self {
            case .cmd: .maskCommand
            case .ctrl: .maskControl
            case .opt: .maskAlternate
            case .shift: .maskShift
            }
        }

        var key: CGKeyCode {
            switch self {
            case .cmd: CGKeyCode(kVK_Command)
            case .ctrl: CGKeyCode(kVK_Control)
            case .opt: CGKeyCode(kVK_Option)
            case .shift: CGKeyCode(kVK_Shift)
            }
        }
    }

    let key: CGKeyCode
    let modifiers: [Modifier]

    private static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow,
        "down": kVK_DownArrow, "space": kVK_Space, "tab": kVK_Tab,
        "return": kVK_Return, "escape": kVK_Escape, "backspace": kVK_Delete,
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9,
        "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
        "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
        "f20": kVK_F20,
    ]

    init(key: CGKeyCode, modifiers: [Modifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(_ text: String) {
        let parts = text.lowercased().components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.last, let key = Self.keys[name] else { return nil }
        let modifiers = parts.dropLast().compactMap(Modifier.init(rawValue:))
        guard modifiers.count == parts.count - 1, Set(modifiers).count == modifiers.count else { return nil }
        self.init(key: CGKeyCode(key), modifiers: modifiers)
    }

    func post(from source: CGEventSource?) {
        func send(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }

        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            send(modifier.key, down: true, flags: flags)
        }

        // Mission Control recognizes arrow shortcuts with the flags used by a physical keyboard.
        // https://github.com/AprilNEA/OpenLogi/issues/1653
        let arrowKeys = kVK_LeftArrow...kVK_UpArrow
        let keyFlags = arrowKeys.contains(Int(key)) ? flags.union([.maskSecondaryFn, .maskNumericPad]) : flags
        send(key, down: true, flags: keyFlags)
        send(key, down: false, flags: keyFlags)

        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            send(modifier.key, down: false, flags: flags)
        }
    }
}

struct ButtonBindings {
    let back: KeyShortcut
    let forward: KeyShortcut
    let thumb: (click: KeyShortcut, hold: KeyShortcut)?

    static let userFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mx-mouse-buttons/.env")

    static func loadAtStartup(userFile: URL, defaultsFile: URL) throws -> Self {
        let log = Logger(subsystem: "local.mxmousebuttons", category: "setup")
        do {
            let bindings = try load(from: userFile)
            log.info("Loaded shortcuts from the user configuration")
            return bindings
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            log.info("No user configuration found. Using bundled defaults.")
        } catch {
            log.error("Could not load user shortcuts: \(error.localizedDescription, privacy: .public). Using bundled defaults.")
        }
        return try load(from: defaultsFile)
    }

    static func load(from file: URL) throws -> Self {
        let contents = try String(contentsOf: file, encoding: .utf8)
        var settings: [String: String] = [:]
        let keys = ["BACK", "FORWARD", "THUMB_CLICK", "THUMB_HOLD"]
        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ConfigError("Expected NAME=value on .env line \(offset + 1)") }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard keys.contains(name), settings[name] == nil else {
                throw ConfigError("Unknown or repeated setting on .env line \(offset + 1)")
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first,
               quote == value.last, quote == "\"" || quote == "'" {
                value = String(value.dropFirst().dropLast())
            }
            settings[name] = value
        }

        func shortcut(_ name: String) throws -> KeyShortcut {
            guard let value = settings[name], let shortcut = KeyShortcut(value) else {
                throw ConfigError("Missing or invalid shortcut for \(name)")
            }
            return shortcut
        }

        let thumb = settings["THUMB_CLICK"] == nil && settings["THUMB_HOLD"] == nil
            ? nil : (click: try shortcut("THUMB_CLICK"), hold: try shortcut("THUMB_HOLD"))
        return Self(back: try shortcut("BACK"), forward: try shortcut("FORWARD"), thumb: thumb)
    }
}

struct ConfigError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
