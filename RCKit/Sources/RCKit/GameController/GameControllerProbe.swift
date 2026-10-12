import Foundation
import GameController

/// Lists everything Apple's GameController framework exposes (controllers, keyboards, mice) and
/// every element's live value.
///
/// It polls instead of registering value-changed handlers. The UI reads at its own frame rate, and
/// polling avoids callback-isolation surprises. The trade-off is that a button tap shorter than one
/// poll interval (~33 ms) can be missed, which is fine for a probe.
@MainActor
public final class GameControllerProbe {
    public struct Element: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable { case button, axis, dpad, touchpad, other }
        public let id: String
        public let kind: Kind
        public let values: [Float]
        public let isPressed: Bool?
        public let isAnalog: Bool
        public let aliases: [String]

        public var display: String {
            let numbers = values.map { String(format: "%+.3f", $0) }.joined(separator: ", ")
            if let isPressed { return "\(numbers)\(isPressed ? " PRESSED" : "")" }
            return numbers
        }
    }

    public struct Device: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable { case controller, keyboard, mouse }
        public let id: String
        public let kind: Kind
        public let vendorName: String
        public let productCategory: String
        public let details: [String]
        public let elements: [Element]
    }

    public private(set) var devices: [Device] = []

    private let log: ProbeLog
    private var observers: [NSObjectProtocol] = []
    private var lastValues: [String: [Float]] = [:]
    private var lastLoggedSignature: String?
    private var started = false

    public init(log: ProbeLog) {
        self.log = log
    }

    public func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (.GCControllerDidConnect, "GCControllerDidConnect"),
            (.GCControllerDidDisconnect, "GCControllerDidDisconnect"),
            (.GCKeyboardDidConnect, "GCKeyboardDidConnect"),
            (.GCKeyboardDidDisconnect, "GCKeyboardDidDisconnect"),
            (.GCMouseDidConnect, "GCMouseDidConnect"),
            (.GCMouseDidDisconnect, "GCMouseDidDisconnect"),
        ]
        for (name, label) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log.log(.gc, "Notification: \(label)")
                    self?.poll(logDevices: true)
                }
            })
        }
        log.log(.gc, "GameController probe started")
        poll(logDevices: true)
    }

    /// Reads every element now. Logs value changes (analog changes ≥ 0.02).
    public func poll(logDevices: Bool = false) {
        var result: [Device] = []

        for (index, controller) in GCController.controllers().enumerated() {
            let id = "controller-\(index)-\(controller.vendorName ?? "?")"
            var details = [
                "attachedToDevice=\(controller.isAttachedToDevice)",
                "extendedGamepad=\(controller.extendedGamepad != nil)",
                "microGamepad=\(controller.microGamepad != nil)",
                "motion=\(controller.motion != nil)",
                "playerIndex=\(controller.playerIndex.rawValue)",
            ]
            if let battery = controller.battery {
                details.append("battery=\(Int(battery.batteryLevel * 100))% state=\(battery.batteryState.rawValue)")
            }
            let elements = Self.elements(of: controller.physicalInputProfile)
            result.append(Device(id: id, kind: .controller, vendorName: controller.vendorName ?? "(nil)",
                                 productCategory: controller.productCategory, details: details, elements: elements))
        }

        if let keyboard = GCKeyboard.coalesced {
            let pressed = keyboard.keyboardInput.map { Self.elements(of: $0).filter { $0.isPressed == true } } ?? []
            result.append(Device(id: "keyboard", kind: .keyboard, vendorName: keyboard.vendorName ?? "(nil)",
                                 productCategory: keyboard.productCategory, details: ["showing pressed keys only"],
                                 elements: pressed))
        }

        for (index, mouse) in GCMouse.mice().enumerated() {
            let elements = mouse.mouseInput.map { Self.elements(of: $0) } ?? []
            result.append(Device(id: "mouse-\(index)", kind: .mouse, vendorName: mouse.vendorName ?? "(nil)",
                                 productCategory: mouse.productCategory, details: [], elements: elements))
        }

        // Log the device list when asked, but only if it differs from the last one logged.
        let signature = result.map { "\($0.id):\($0.elements.map(\.id))" }.joined(separator: "|")
        if logDevices, signature != lastLoggedSignature {
            lastLoggedSignature = signature
            if result.isEmpty { log.log(.gc, "No GameController devices (controllers/keyboards/mice)") }
            for device in result {
                log.log(.gc, "\(device.kind.rawValue): vendor=\"\(device.vendorName)\" category=\"\(device.productCategory)\" "
                    + "\(device.details.joined(separator: " ")) elements=[\(device.elements.map(\.id).joined(separator: ", "))]")
            }
        }

        for device in result {
            for element in device.elements {
                let key = "\(device.id)/\(element.id)"
                let previous = lastValues[key]
                if let previous, Self.changed(previous, element.values, analog: element.isAnalog) {
                    log.log(.gc, "\(device.vendorName) \(element.id) = \(element.display)")
                }
                if previous == nil || Self.changed(previous!, element.values, analog: element.isAnalog) {
                    lastValues[key] = element.values
                }
            }
        }

        devices = result
    }

    private static func changed(_ a: [Float], _ b: [Float], analog: Bool) -> Bool {
        guard a.count == b.count else { return true }
        let threshold: Float = analog ? 0.02 : 0.0001
        return zip(a, b).contains { abs($0 - $1) >= threshold }
    }

    private static func elements(of profile: GCPhysicalInputProfile) -> [Element] {
        profile.elements.map { name, element -> Element in
            let aliases = element.aliases.sorted()
            if let button = element as? GCControllerButtonInput {
                return Element(id: name, kind: .button, values: [button.value], isPressed: button.isPressed,
                               isAnalog: element.isAnalog, aliases: aliases)
            } else if let axis = element as? GCControllerAxisInput {
                return Element(id: name, kind: .axis, values: [axis.value], isPressed: nil,
                               isAnalog: element.isAnalog, aliases: aliases)
            } else if let pad = element as? GCControllerDirectionPad {
                return Element(id: name, kind: .dpad, values: [pad.xAxis.value, pad.yAxis.value], isPressed: nil,
                               isAnalog: element.isAnalog, aliases: aliases)
            } else if let touchpad = element as? GCControllerTouchpad {
                return Element(id: name, kind: .touchpad,
                               values: [touchpad.touchSurface.xAxis.value, touchpad.touchSurface.yAxis.value],
                               isPressed: touchpad.button.isPressed, isAnalog: element.isAnalog, aliases: aliases)
            } else {
                return Element(id: name, kind: .other, values: [], isPressed: nil,
                               isAnalog: element.isAnalog, aliases: aliases)
            }
        }
        .sorted { $0.id < $1.id }
    }
}
