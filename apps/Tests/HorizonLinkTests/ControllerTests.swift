import Foundation
import Testing
@testable import HorizonLink

struct ControllerTests {
    typealias Button = DMStream.Button

    @Test func facesFollowThePositionsByDefault() {
        var state = ControllerState()
        state.south = true
        state.north = true
        #expect(PadMapper().pad(player: 0, state: state).buttons == Button.b | Button.x)
        #expect(PadMapper(layout: .labeled).pad(player: 0, state: state).buttons == Button.a | Button.y)
    }

    @Test func everyControlHasItsBit() {
        var state = ControllerState()
        state.leftShoulder = true
        state.rightShoulder = true
        state.leftTrigger = 0.5
        state.rightTrigger = 0.1
        state.up = true
        state.left = true
        state.menu = true
        state.options = true
        state.leftThumb = true
        state.rightThumb = true
        let pad = PadMapper().pad(player: 2, state: state)
        #expect(pad.player == 2)
        #expect(pad.buttons == Button.l | Button.r | Button.zl | Button.up | Button.left | Button.plus | Button.minus | Button.leftStick | Button.rightStick)
    }

    @Test func sticksHaveARadialDeadzoneAndFullRange() {
        let mapper = PadMapper()
        var state = ControllerState()
        state.leftX = 0.05
        state.leftY = -0.05
        #expect(mapper.pad(player: 0, state: state).leftX == 0)
        state.leftX = 1
        state.leftY = 0
        #expect(mapper.pad(player: 0, state: state).leftX == Button.stickMax)
        state.leftX = 0
        state.leftY = -1
        #expect(mapper.pad(player: 0, state: state).leftY == -Button.stickMax)
        state.rightX = 2
        state.rightY = 2
        let pad = mapper.pad(player: 0, state: state)
        #expect(pad.rightX == pad.rightY)
        #expect(pad.rightX > 23000 && pad.rightX < 23200)
        state.rightX = .nan
        #expect(mapper.pad(player: 0, state: state).rightX == 0)
    }

    @Test func theScheduleSendsChangesAndARefresh() {
        var schedule = PadSchedule()
        let idle = DMStream.Pad(player: 0)
        let first = schedule.next(idle, now: 1_000)
        let repeated = schedule.next(idle, now: 2_000)
        let pressed = DMStream.Pad(player: 0, buttons: Button.a)
        let changed = schedule.next(pressed, now: 3_000)
        let refreshed = schedule.next(pressed, now: 3_000 + PadSchedule.refreshNs)
        #expect(first?.sequence == 1)
        #expect(repeated == nil)
        #expect(changed?.sequence == 2)
        #expect(refreshed?.sequence == 3)
    }

    @Test func holdingPlusAndMinusOpensTheMenuOnce() {
        var combo = MenuCombo()
        let both = DMStream.Pad(player: 0, buttons: Button.plus | Button.minus | Button.a)
        var result = combo.filter(both, now: 0)
        #expect(result.pad.buttons == Button.a)
        #expect(!result.open)
        result = combo.filter(both, now: MenuCombo.holdNs)
        #expect(result.open)
        let again = combo.filter(both, now: MenuCombo.holdNs * 2)
        #expect(!again.open)
        let plus = DMStream.Pad(player: 0, buttons: Button.plus)
        let released = combo.filter(plus, now: MenuCombo.holdNs * 3)
        #expect(released.pad == plus)
        #expect(!released.open)
    }
}
