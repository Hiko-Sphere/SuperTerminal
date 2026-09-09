import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ApexTerminal

/// The shortcut table is the contract with the ⌘-hold overlay: one declaration per key,
/// a title for each, and the same table wherever it is exposed — as SwiftUI shortcuts in
/// the shell and as `UIKeyCommand`s on the terminal view.
@Suite struct AppShortcutTests {
    @Test func everyShortcutIsDeclaredOnceWithATitle() {
        let all = AppShortcut.allCases
        let keys = all.map { "\($0.modifiers.rawValue):\($0.input)" }
        #expect(Set(keys).count == keys.count, "no key equivalent may be declared twice")
        #expect(all.allSatisfy { !$0.title.isEmpty })
        #expect(all.filter { $0.sessionNumber != nil }.count == 9, "⌘1–⌘9")
        #expect(AppShortcut.session7.input == "7")
        #expect(AppShortcut.nextSession.modifiers == [.command, .shift])
    }

    /// The SwiftUI form of every shortcut is the same key as the UIKit form: one table,
    /// two spellings, and a mismatch would make ⌘K open the palette from a terminal but
    /// not from the host list.
    @Test func swiftUIAndUIKitFormsAgree() {
        for shortcut in AppShortcut.allCases {
            #expect(shortcut.input.count == 1, "\(shortcut.rawValue) must be a single key")
            #expect(shortcut.keyEquivalent.character == shortcut.input.first)
            #expect(shortcut.eventModifiers.contains(.command))
            // Every modifier must agree between the two spellings, in both directions.
            // This used to assert that nothing used Option, which was true only by
            // accident until the pane commands needed it (D-055) — and an assertion that
            // holds by accident stops being a check the moment the accident ends.
            #expect(shortcut.eventModifiers.contains(.shift) == shortcut.modifiers.contains(.shift))
            #expect(shortcut.eventModifiers.contains(.option) == shortcut.modifiers.contains(.alternate))
            #expect(shortcut.eventModifiers.contains(.control) == shortcut.modifiers.contains(.control))
        }
    }

    /// Two shortcuts on the same key and modifiers would mean one of them never fires,
    /// and which one is up to UIKit. The pane commands deliberately share letters with
    /// their session-level twins, so the pairs are only distinct because of Option.
    @Test func noTwoShortcutsShareAKeyCombination() {
        var seen: [String: AppShortcut] = [:]
        for shortcut in AppShortcut.allCases {
            let combination = "\(shortcut.modifiers.rawValue):\(shortcut.input)"
            if let clash = seen[combination] {
                Issue.record("\(shortcut.rawValue) and \(clash.rawValue) both use \(combination)")
            }
            seen[combination] = shortcut
        }
    }

    @Test @MainActor func keyCommandsRoundTripThroughThePropertyList() {
        let commands = AppShortcut.keyCommands(action: #selector(TerminalInputView.performAppShortcut(_:)))
        #expect(commands.count == AppShortcut.allCases.count)
        for command in commands {
            #expect(AppShortcut(command: command) != nil, "\(command.title) must map back to its shortcut")
        }
    }

    @Test @MainActor func theTerminalExposesTheWholeTable() {
        let terminal = TerminalInputView()
        let fromTerminal = Set((terminal.keyCommands ?? []).compactMap { $0.propertyList as? String })
        #expect(fromTerminal == Set(AppShortcut.allCases.map(\.rawValue)))
    }

    @Test @MainActor func nothingIsAvailableWithoutAScene() {
        let terminal = TerminalInputView()
        for command in terminal.keyCommands ?? [] where AppShortcut(command: command) != nil {
            terminal.validate(command)
            #expect(command.attributes.contains(.disabled), "\(command.title) must be disabled with nothing to act on")
        }
    }
}
