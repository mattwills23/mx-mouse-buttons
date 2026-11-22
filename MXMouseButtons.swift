import AppKit
import CoreGraphics
import IOKit.hid
import OSLog
import ServiceManagement

// The Unifying receiver exposes this separate vendor interface for HID++.
// We never open its mouse or keyboard interface.
// All mutable state is confined to the main run loop and main queue.
final class MXSpaces: @unchecked Sendable {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private let keyboard = CGEventSource(stateID: .hidSystemState)
    private let log = Logger(subsystem: "local.mxmousebuttons", category: "mouse")
    private let back: UInt16 = 0x0053
    private let forward: UInt16 = 0x0056
    private let thumb: UInt16 = 0x00c3
    private let bindings: ButtonBindings?
    private var thumbPress: (deadline: DispatchTime, timer: DispatchWorkItem)?
    private var receiver: IOHIDDevice?
    private var receiverID: UInt64 = 0
    private var slot: UInt8 = 0
    private var controls: UInt8 = 0
    private var held = Set<UInt16>()
    private var configured: [UInt16] = []
    private var pending: (slot: UInt8, feature: UInt8, command: UInt8, reply: ([UInt8]?) -> Void)?
    private var sequence: UInt8 = 0
    private var rescan: DispatchWorkItem?
    private var wakeObserver: Any?
    private var shutdown: DispatchSourceSignal?
    private var probe = false
    private var requestID: UInt64 = 0

    init(bindings: ButtonBindings? = nil) {
        self.bindings = bindings
    }

    func run(probe: Bool) -> Bool {
        self.probe = probe
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x046d,
            kIOHIDProductIDKey: 0xc52b,
            kIOHIDPrimaryUsagePageKey: 0xff00,
            kIOHIDPrimaryUsageKey: 1
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<MXSpaces>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MXSpaces>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, _, id, data, length in
            guard result == kIOReturnSuccess, let context, id == 0x10 || id == 0x11 else { return }
            let helper = Unmanaged<MXSpaces>.fromOpaque(context).takeUnretainedValue()
            guard let receiver = helper.receiver, sender == Unmanaged.passUnretained(receiver).toOpaque() else { return }
            helper.receive(UnsafeBufferPointer(start: data, count: length))
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else {
            log.error("Could not open the Unifying HID interface: \(result)")
            return false
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleScan() }
        signal(SIGTERM, SIG_IGN)
        let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        shutdown.setEventHandler { [weak self] in
            self?.restore()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        shutdown.resume()
        self.shutdown = shutdown
        CFRunLoopRun()
        return true
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private func attach(_ device: IOHIDDevice) {
        guard receiver == nil else { return }
        receiver = device
        receiverID = registryID(device)
        log.info("Unifying receiver connected")
        scheduleScan()
    }

    private func detach(_ device: IOHIDDevice) {
        guard registryID(device) == receiverID else { return }
        rescan?.cancel()
        receiver = nil
        pending = nil
        slot = 0
        controls = 0
        configured.removeAll()
        clearHeld()
    }

    private func scheduleScan() {
        rescan?.cancel()
        let scan = DispatchWorkItem { [weak self] in
            guard let self, self.receiver != nil else { return }
            guard self.pending == nil else {
                self.scheduleScan()
                return
            }
            self.scan(1)
        }
        rescan = scan
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: scan)
    }

    private func scan(_ candidate: UInt8) {
        guard candidate <= 6 else {
            log.info("No active MX Master found on the receiver")
            if probe {
                print("No active MX Master found on the receiver.")
                CFRunLoopStop(CFRunLoopGetMain())
            }
            return
        }
        request(candidate, 0, 0, [0, 5]) { [self] response in
            guard let index = response?.first, index != 0 else {
                scan(candidate + 1)
                return
            }
            request(candidate, index, 0, []) { [self] response in
                guard let length = response?.first, length >= 9 else {
                    scan(candidate + 1)
                    return
                }
                // The first chunk covers the model prefix even for longer names.
                request(candidate, index, 1, [0]) { [self] response in
                    let name = String(decoding: (response ?? []).prefix(Int(length)), as: UTF8.self)
                    guard name.hasPrefix("MX Master") else {
                        scan(candidate + 1)
                        return
                    }
                    log.notice("Found an MX Master in receiver slot \(candidate)")
                    request(candidate, 0, 0, [0x1b, 0x04]) { [self] response in
                        guard let feature = response?.first, feature != 0 else {
                            log.error("MX Master does not expose HID++ reprogrammable controls")
                            return
                        }
                        if probe {
                            print("MX Master found in receiver slot \(candidate), controls feature available.")
                            CFRunLoopStop(CFRunLoopGetMain())
                            return
                        }
                        guard CGPreflightPostEventAccess() else { return }
                        if slot != candidate { restore() }
                        slot = candidate
                        controls = feature
                        var buttons = [back, forward]
                        if bindings?.thumb != nil { buttons.append(thumb) }
                        enable(buttons[...])
                    }
                }
            }
        }
    }

    private func enable(_ buttons: ArraySlice<UInt16>) {
        guard let button = buttons.first else {
            log.notice("Configured Back and Forward\(self.configured.contains(self.thumb) ? " and thumb shortcuts" : "", privacy: .public)")
            return
        }
        request(slot, controls, 3, reporting(button, divert: true)) { [self] reply in
            guard let reply, reply.count >= 3, reply[2] & 1 != 0 else {
                // The request may have succeeded even if its reply was lost.
                send(slot, controls, 0x3f, reporting(button, divert: false))
                if button == thumb {
                    configured.removeAll { $0 == thumb }
                    clearHeld()
                    log.error("Could not remap the thumb button. Back and Forward are active.")
                    return
                }
                restore()
                log.error("Could not enable both side buttons")
                return
            }
            if !configured.contains(button) { configured.append(button) }
            enable(buttons.dropFirst())
        }
    }

    private func reporting(_ button: UInt16, divert: Bool) -> [UInt8] {
        [UInt8(button >> 8), UInt8(truncatingIfNeeded: button), divert ? 3 : 2, 0, 0]
    }

    private func restore() {
        for button in configured {
            send(slot, controls, 0x3f, reporting(button, divert: false))
        }
        configured.removeAll()
        clearHeld()
    }

    private func clearHeld() {
        thumbPress?.timer.cancel()
        thumbPress = nil
        held.removeAll()
    }

    @discardableResult
    private func send(_ slot: UInt8, _ feature: UInt8, _ command: UInt8, _ arguments: [UInt8]) -> Bool {
        guard let receiver else { return false }
        let report: UInt8 = arguments.count <= 3 ? 0x10 : 0x11
        let length = report == 0x10 ? 7 : 20
        var packet = [report, slot, feature, command] + arguments
        packet += Array(repeating: 0, count: length - packet.count)
        let result = IOHIDDeviceSetReport(receiver, kIOHIDReportTypeOutput, Int(report), packet, packet.count)
        return result == kIOReturnSuccess
    }

    private func request(
        _ slot: UInt8, _ feature: UInt8, _ function: UInt8, _ arguments: [UInt8],
        reply: @escaping ([UInt8]?) -> Void
    ) {
        sequence = sequence % 13 + 1
        let command = function << 4 | sequence
        guard send(slot, feature, command, arguments) else {
            reply(nil)
            return
        }
        pending = (slot, feature, command, reply)
        requestID += 1
        let id = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650)) { [weak self] in
            guard let self, self.requestID == id, let pending = self.pending else { return }
            self.pending = nil
            pending.reply(nil)
        }
    }

    private func receive(_ packet: UnsafeBufferPointer<UInt8>) {
        guard packet.count >= 7, packet[0] == 0x10 || packet[0] == 0x11 else { return }
        if let pending, packet[1] == pending.slot {
            let success = packet[2] == pending.feature && packet[3] == pending.command
            let error = (packet[2] == 0xff || packet[2] == 0x8f)
                && packet[3] == pending.feature && packet[4] == pending.command
            if success || error {
                self.pending = nil
                pending.reply(success ? Array(packet.dropFirst(4)) : nil)
                return
            }
        }

        // Unifying connection notifications let us restore diversion after the mouse reconnects.
        if packet[0] == 0x10, (1...6).contains(packet[1]), packet[2] == 0x41 {
            if packet[1] == slot { clearHeld() }
            scheduleScan()
            return
        }

        guard controls != 0, packet[0] == 0x11, packet[1] == slot,
              packet[2] == controls, packet[3] == 0, packet.count >= 12 else { return }
        var pressed = Set<UInt16>()
        for offset in stride(from: 4, to: 12, by: 2) {
            let button = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
            if configured.contains(button) { pressed.insert(button) }
        }
        let started = pressed.subtracting(held)
        let thumbReleased = held.contains(thumb) && !pressed.contains(thumb)
        held = pressed
        guard let bindings else { return }
        for button in started {
            guard CGPreflightPostEventAccess() else {
                restore()
                return
            }
            switch button {
            case back: bindings.back.post(from: keyboard)
            case forward: bindings.forward.post(from: keyboard)
            case thumb: beginThumbPress()
            default: break
            }
        }
        if thumbReleased, let press = thumbPress {
            finishThumbPress(heldLongEnough: DispatchTime.now() >= press.deadline)
        }
    }

    private func beginThumbPress() {
        let deadline = DispatchTime.now() + .milliseconds(450)
        let timer = DispatchWorkItem { [weak self] in
            self?.finishThumbPress(heldLongEnough: true)
        }
        thumbPress = (deadline, timer)
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: timer)
    }

    private func finishThumbPress(heldLongEnough: Bool) {
        guard let press = thumbPress, let bindings = bindings?.thumb else { return }
        press.timer.cancel()
        thumbPress = nil
        guard CGPreflightPostEventAccess() else {
            restore()
            return
        }
        let shortcut = heldLongEnough ? bindings.hold : bindings.click
        shortcut.post(from: keyboard)
        log.info("Posted thumb \(heldLongEnough ? "hold" : "click", privacy: .public) shortcut")
    }
}

func defaultBindingsFile() throws -> URL {
    guard let file = Bundle.main.url(forResource: "defaults", withExtension: "env") else {
        throw ConfigError("This build is missing its shortcut configuration")
    }
    return file
}

@main
struct MXMouseButtons {
    static func main() {
        let service = SMAppService.mainApp
        let log = Logger(subsystem: "local.mxmousebuttons", category: "setup")
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "--validate-config":
                let path = CommandLine.arguments.dropFirst(2).first
                _ = try ButtonBindings.load(from: path.map { URL(fileURLWithPath: $0) } ?? defaultBindingsFile())
            case "--status":
                print("Login item: \(service.status.rawValue) (1 = enabled)")
                print("Can post events: \(CGPreflightPostEventAccess())")
            case "--unregister":
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            case "--register":
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
                print("Login item: \(service.status.rawValue) (1 = enabled)")
            case "--probe":
                if !MXSpaces().run(probe: true) { exit(1) }
            default:
                let bindings = try ButtonBindings.loadAtStartup(
                    userFile: ButtonBindings.userFile,
                    defaultsFile: defaultBindingsFile()
                )
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
                guard CGPreflightPostEventAccess() else {
                    _ = CGRequestPostEventAccess()
                    exit(1)
                }
                if !MXSpaces(bindings: bindings).run(probe: false) { exit(1) }
            }
        } catch {
            log.error("Setup failed: \(error.localizedDescription, privacy: .public)")
            FileHandle.standardError.write(Data("MX Mouse Buttons: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
