import Foundation
import GameController
import HorizonLink

struct ControllerSink: Sendable {
    var pad: @Sendable (PadPacket) -> Void
    var pads: @Sendable (DMStream.Pads) -> Void
}

final class ControllerInput: @unchecked Sendable {
    private struct Slot {
        let controller: GCController
        var combo = MenuCombo()
        var schedule = PadSchedule()
    }

    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.tv.input", qos: .userInteractive)
    private let menu: @Sendable () -> Void
    private let changed: @Sendable ([String]) -> Void
    private var slots: [Slot?] = Array(repeating: nil, count: 4)
    private var remotes: [GCController] = []
    private var sink: ControllerSink?
    private var muted = false
    private var mapper = PadMapper()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    init(menu: @escaping @Sendable () -> Void, changed: @escaping @Sendable ([String]) -> Void) {
        self.menu = menu
        self.changed = changed
    }

    func start() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async { self.reconcile() }
            })
        }
        queue.async { [self] in reconcile() }
    }

    func activate(_ sink: ControllerSink) {
        queue.async { [self] in
            self.sink = sink
            muted = false
            for index in slots.indices { slots[index]?.schedule.reset() }
            sink.pads(pads())
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }

    func deactivate() {
        queue.async { [self] in
            muted = true
            tick()
            timer?.cancel()
            timer = nil
            sink = nil
        }
    }

    func setMuted(_ value: Bool) {
        queue.async { [self] in
            muted = value
            tick()
        }
    }

    func setLayout(_ layout: ButtonLayout) {
        queue.async { [self] in mapper.layout = layout }
    }

    private func reconcile() {
        let current = GCController.controllers()
        var dirty = false
        for index in slots.indices {
            guard let slot = slots[index], !current.contains(where: { $0 === slot.controller }) else { continue }
            slots[index] = nil
            dirty = true
        }
        remotes.removeAll { remote in !current.contains { $0 === remote } }
        for controller in current {
            if controller.extendedGamepad != nil {
                guard !slots.contains(where: { $0?.controller === controller }) else { continue }
                guard let free = slots.firstIndex(where: { $0 == nil }) else { continue }
                adopt(controller, slot: free)
                dirty = true
            } else if let micro = controller.microGamepad, !remotes.contains(where: { $0 === controller }) {
                controller.handlerQueue = queue
                micro.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard let self, pressed, sink != nil, !muted else { return }
                    menu()
                }
                remotes.append(controller)
            }
        }
        guard dirty else { return }
        changed(slots.compactMap { $0.map { Self.label($0.controller) } })
        sink?.pads(pads())
    }

    private func adopt(_ controller: GCController, slot index: Int) {
        controller.handlerQueue = queue
        controller.playerIndex = GCControllerPlayerIndex(rawValue: index) ?? .indexUnset
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in self?.send(index) }
        slots[index] = Slot(controller: controller)
    }

    private func tick() {
        for index in slots.indices { send(index) }
    }

    private func send(_ index: Int) {
        guard let sink, var slot = slots[index] else { return }
        let now = LinkClock.nowNs()
        var pad = DMStream.Pad(player: UInt8(index))
        if !muted, let gamepad = slot.controller.extendedGamepad {
            let filtered = slot.combo.filter(mapper.pad(player: UInt8(index), state: Self.state(gamepad)), now: now)
            pad = filtered.pad
            if filtered.open { menu() }
        }
        if let packet = slot.schedule.next(pad, now: now) { sink.pad(packet) }
        slots[index] = slot
    }

    private func pads() -> DMStream.Pads {
        var mask: UInt32 = 0
        var styles = [UInt8](repeating: 0, count: DMStream.players)
        for (index, slot) in slots.enumerated() where slot != nil {
            mask |= 1 << UInt32(index)
            styles[index] = DMStream.styleProController
        }
        return DMStream.Pads(mask: mask, styles: styles)
    }

    static func label(_ controller: GCController) -> String {
        controller.vendorName ?? controller.productCategory
    }

    static func state(_ gamepad: GCExtendedGamepad) -> ControllerState {
        var state = ControllerState()
        state.south = gamepad.buttonA.isPressed
        state.east = gamepad.buttonB.isPressed
        state.west = gamepad.buttonX.isPressed
        state.north = gamepad.buttonY.isPressed
        state.leftShoulder = gamepad.leftShoulder.isPressed
        state.rightShoulder = gamepad.rightShoulder.isPressed
        state.leftTrigger = gamepad.leftTrigger.value
        state.rightTrigger = gamepad.rightTrigger.value
        state.up = gamepad.dpad.up.isPressed
        state.down = gamepad.dpad.down.isPressed
        state.left = gamepad.dpad.left.isPressed
        state.right = gamepad.dpad.right.isPressed
        state.menu = gamepad.buttonMenu.isPressed
        state.options = gamepad.buttonOptions?.isPressed ?? false
        state.leftThumb = gamepad.leftThumbstickButton?.isPressed ?? false
        state.rightThumb = gamepad.rightThumbstickButton?.isPressed ?? false
        state.leftX = gamepad.leftThumbstick.xAxis.value
        state.leftY = gamepad.leftThumbstick.yAxis.value
        state.rightX = gamepad.rightThumbstick.xAxis.value
        state.rightY = gamepad.rightThumbstick.yAxis.value
        return state
    }
}
