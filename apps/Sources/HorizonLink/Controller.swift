import Foundation

public struct ControllerState: Sendable, Equatable {
    public var south = false
    public var east = false
    public var west = false
    public var north = false
    public var leftShoulder = false
    public var rightShoulder = false
    public var leftTrigger: Float = 0
    public var rightTrigger: Float = 0
    public var up = false
    public var down = false
    public var left = false
    public var right = false
    public var menu = false
    public var options = false
    public var leftThumb = false
    public var rightThumb = false
    public var leftX: Float = 0
    public var leftY: Float = 0
    public var rightX: Float = 0
    public var rightY: Float = 0

    public init() {}
}

public enum ButtonLayout: String, Sendable, CaseIterable {
    case positional
    case labeled
}

public struct PadMapper: Sendable, Equatable {
    public var layout: ButtonLayout
    public var triggerThreshold: Float
    public var deadzone: Float

    public init(layout: ButtonLayout = .positional, triggerThreshold: Float = 0.3, deadzone: Float = 0.08) {
        self.layout = layout
        self.triggerThreshold = triggerThreshold
        self.deadzone = deadzone
    }

    public func pad(player: UInt8, state: ControllerState) -> DMStream.Pad {
        typealias Button = DMStream.Button
        var buttons: UInt64 = 0
        let faces: [(Bool, UInt64, UInt64)] = [
            (state.south, Button.b, Button.a),
            (state.east, Button.a, Button.b),
            (state.west, Button.y, Button.x),
            (state.north, Button.x, Button.y),
        ]
        for (pressed, positional, labeled) in faces where pressed {
            buttons |= layout == .positional ? positional : labeled
        }
        let others: [(Bool, UInt64)] = [
            (state.leftShoulder, Button.l),
            (state.rightShoulder, Button.r),
            (state.leftTrigger >= triggerThreshold, Button.zl),
            (state.rightTrigger >= triggerThreshold, Button.zr),
            (state.up, Button.up),
            (state.down, Button.down),
            (state.left, Button.left),
            (state.right, Button.right),
            (state.menu, Button.plus),
            (state.options, Button.minus),
            (state.leftThumb, Button.leftStick),
            (state.rightThumb, Button.rightStick),
        ]
        for (pressed, bit) in others where pressed { buttons |= bit }
        let leftStick = stick(state.leftX, state.leftY)
        let rightStick = stick(state.rightX, state.rightY)
        return DMStream.Pad(
            player: player, buttons: buttons, leftX: leftStick.x, leftY: leftStick.y, rightX: rightStick.x, rightY: rightStick.y
        )
    }

    func stick(_ x: Float, _ y: Float) -> (x: Int16, y: Int16) {
        let length = (x * x + y * y).squareRoot()
        guard length > deadzone, length.isFinite else { return (0, 0) }
        let scaled = min(1, (length - deadzone) / (1 - deadzone)) / length
        return (Self.axis(x * scaled), Self.axis(y * scaled))
    }

    static func axis(_ value: Float) -> Int16 {
        Int16((max(-1, min(1, value)) * Float(DMStream.Button.stickMax)).rounded())
    }
}

public struct PadSchedule: Sendable {
    public static let refreshNs: UInt64 = 50_000_000

    private var last: DMStream.Pad?
    private var lastSentNs: UInt64 = 0
    private var sequence: UInt32 = 0

    public init() {}

    public mutating func next(_ pad: DMStream.Pad, now: UInt64) -> PadPacket? {
        guard pad != last || now &- lastSentNs >= Self.refreshNs else { return nil }
        last = pad
        lastSentNs = now
        sequence &+= 1
        return PadPacket(sequence: sequence, pad: pad)
    }

    public mutating func reset() {
        last = nil
        lastSentNs = 0
    }
}

public struct MenuCombo: Sendable {
    public static let holdNs: UInt64 = 1_000_000_000
    public static let bits = DMStream.Button.plus | DMStream.Button.minus

    private var heldSince: UInt64?
    private var fired = false

    public init() {}

    public mutating func filter(_ pad: DMStream.Pad, now: UInt64) -> (pad: DMStream.Pad, open: Bool) {
        guard pad.buttons & Self.bits == Self.bits else {
            heldSince = nil
            fired = false
            return (pad, false)
        }
        var quiet = pad
        quiet.buttons &= ~Self.bits
        let since = heldSince ?? now
        heldSince = since
        guard !fired, now &- since >= Self.holdNs else { return (quiet, false) }
        fired = true
        return (quiet, true)
    }
}
