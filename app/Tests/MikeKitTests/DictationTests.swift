import Testing
@testable import MikeKit

@Suite struct DictationKeyTests {
    @Test func holdFinishesOnRelease() {
        var k = DictationKey()
        #expect(k.rightCommand(down: true, at: 0) == .start)
        #expect(k.rightCommand(down: false, at: 1) == .finish)
        #expect(!k.latched)
    }

    @Test func tapLatchesAndSecondTapFinishes() {
        var k = DictationKey()
        #expect(k.rightCommand(down: true, at: 0) == .start)
        #expect(k.rightCommand(down: false, at: DictationKey.tapLimit / 2) == nil)
        #expect(k.latched)
        #expect(k.key(escape: false) == nil)  // typing elsewhere keeps dictating
        #expect(k.rightCommand(down: true, at: 5) == nil)
        #expect(k.rightCommand(down: false, at: 5.1) == .finish)
        #expect(k.rightCommand(down: true, at: 6) == .start)  // and the next press starts afresh
    }

    @Test func escapeCancelsClickMode() {
        var k = DictationKey()
        _ = k.rightCommand(down: true, at: 0)
        _ = k.rightCommand(down: false, at: 0.1)
        #expect(k.key(escape: true) == .cancel)
        #expect(!k.latched)
        #expect(k.rightCommand(down: false, at: 1) == nil)
    }

    @Test func chordIsAShortcut() {
        var k = DictationKey()
        #expect(k.rightCommand(down: true, at: 0) == .start)
        #expect(k.key(escape: false) == .cancel)  // ⌘C
        #expect(k.rightCommand(down: false, at: 0.1) == nil)  // its release neither finishes nor latches
        #expect(!k.latched)
        // A shortcut on the second press of click mode keeps dictating.
        _ = k.rightCommand(down: true, at: 1)
        _ = k.rightCommand(down: false, at: 1.1)
        _ = k.rightCommand(down: true, at: 2)
        #expect(k.key(escape: false) == nil)
        #expect(k.rightCommand(down: false, at: 2.1) == nil)
        #expect(k.latched)
    }
}
