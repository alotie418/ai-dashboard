import XCTest

/// G4 — the menu item that brings the main window back, and the rule that no other command is
/// left lit up while there is no window to act on.
///
/// ## What this is defending
///
/// The Electron 1.0 was rejected under Guideline 4 for exactly one shape: close the main window
/// and no menu item reopens it. The native build was measured in the same shape before this
/// round — `CommandGroup(replacing: .newItem)` had taken the slot SwiftUI puts "New Window" in,
/// the Window menu greyed out completely once the last window closed, and only the Dock icon
/// could recover. This file pins the three structural facts that stop it coming back:
///
///  1. the main scene is a `Window`, not a `WindowGroup` — so "reopen" cannot become "open a
///     second one";
///  2. the Window menu carries a reopen item titled `app.name` with ⌘0, targeting that scene;
///  3. every command that acts on the main window is disabled while it is closed — and the
///     reopen item is NOT, because it is the one that has work to do then.
///
/// ## Why every assertion runs on comment-STRIPPED source
///
/// This is the trap this particular guard sits on top of, and it is not hypothetical: the files
/// under test carry long comments that name `WindowGroup`, `openWindow`, `.newItem`, `⌘0` and
/// `mainWindowIsOpen` — because they explain the very change being pinned. A guard that grepped
/// raw text would therefore stay green if someone deleted the command and left the paragraph
/// describing it, which is the most likely way this rots. ``strippingComments(_:)`` removes `//`
/// and `/* */` before anything is matched, and
/// ``testAGuardBuiltOnRawTextWouldPassOnCommentsAlone`` demonstrates the difference on a sample
/// where the naive check passes and the real one fails.
final class WindowReopenCommandGuardTests: XCTestCase {

    // MARK: - Pinned literals

    static let sceneIDSymbol = "SoloLedgerApp.mainWindowID"
    static let reopenTitleKey = #"model.t("app.name")"#
    static let reopenShortcut = #".keyboardShortcut("0", modifiers: .command)"#
    static let disableModifier = ".disabled(!model.mainWindowIsOpen)"

    /// The commands that need the main window. The count is the assertion: adding a command
    /// without deciding what it does with no window has to break this test, not slip through.
    static let windowActingCommandCount = 4

    // MARK: - Reading

    static func appSource(_ relative: String) throws -> String {
        try String(contentsOf: AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/App/\(relative)"), encoding: .utf8)
    }

    /// Source with `//` line comments and `/* */` block comments removed. String literals are
    /// left alone: a `//` inside a literal would be mangled by a naive stripper, and the keys
    /// this file matches on (`"app.name"`, `"0"`) live in literals.
    static func strippingComments(_ text: String) -> String {
        var out = ""
        var inLine = false, inBlock = false, inString = false, escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index) < text.endIndex ? text[text.index(after: index)] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inBlock {
                if c == "*", next == "/" { inBlock = false; index = text.index(after: index) }
            } else if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "/", next == "/" {
                inLine = true; index = text.index(after: index)
            } else if c == "/", next == "*" {
                inBlock = true; index = text.index(after: index)
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            index = text.index(after: index)
        }
        return out
    }

    /// Fail-closed accessor: an empty read makes every `contains` assertion below false in a way
    /// that looks like a real failure, but the count assertions would pass over nothing. Gate
    /// first, assert second — the same shape `AppVersionGuardTests` uses on its configurations.
    func requireStrippedSource(
        _ relative: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let stripped = Self.strippingComments(try Self.appSource(relative))
        XCTAssertGreaterThan(stripped.count, 200, """
            \(relative) stripped to \(stripped.count) characters. Every assertion about it is a \
            `contains`, and `contains` over nothing is just false — but the counting ones would \
            pass. This stops here.
            """, file: file, line: line)
        return stripped
    }

    // MARK: - (1) the scene type

    func testTheMainSceneIsASingleInstanceWindow() throws {
        let code = try requireStrippedSource("SoloLedgerApp.swift")
        XCTAssertTrue(code.contains("Window(\"SoloLedger\", id: Self.mainWindowID)"), """
            The main scene is no longer the single-instance `Window`. If it went back to \
            `WindowGroup`, the reopen command silently becomes "open ANOTHER main window" — the \
            user gets two windows over one ledger, each able to raise its own editor sheet.
            """)
        XCTAssertFalse(code.contains("WindowGroup"), """
            `WindowGroup` is back in the scene body. See above — with a group, \
            `openWindow(id:)` adds a member rather than restoring the one that was closed.
            """)
        XCTAssertTrue(code.contains("static let mainWindowID"),
                      "the scene id the reopen command targets is gone")
    }

    func testTheWindowFlagIsWrittenByTheSceneAndPublished() throws {
        let scene = try requireStrippedSource("SoloLedgerApp.swift")
        XCTAssertTrue(scene.contains("model.mainWindowIsOpen = true"),
                      "nothing sets the flag when the window appears, so every command stays disabled forever")
        XCTAssertTrue(scene.contains("model.mainWindowIsOpen = false"),
                      "nothing clears the flag when the window closes, so the pre-G4 lit-but-inert state returns")
        let model = try requireStrippedSource("AppModel.swift")
        XCTAssertTrue(model.contains("@Published var mainWindowIsOpen"), """
            `mainWindowIsOpen` is no longer `@Published`. A plain property is correct when read \
            and stale on screen: SwiftUI would never re-evaluate the `.disabled(…)`.
            """)
    }

    // MARK: - (2) the reopen item

    func testTheReopenCommandExistsInTheWindowMenuWithItsShortcut() throws {
        let code = try requireStrippedSource("AppCommands.swift")
        XCTAssertTrue(code.contains("CommandGroup(after: .windowList)"), """
            The reopen item is not in the Window menu any more. That menu is where the reviewer \
            and the user look for it, and it is where the Electron 1.0.1 remediation put its own.
            """)
        XCTAssertTrue(code.contains(Self.reopenTitleKey), """
            The reopen item no longer takes its title from \(Self.reopenTitleKey). A literal \
            here would stop following the UI language on the six-language switch.
            """)
        XCTAssertTrue(code.contains(Self.reopenShortcut), """
            ⌘0 is gone from the reopen item. The shortcut is part of the decision, not decoration.
            """)
        XCTAssertTrue(code.contains("openWindow(id: \(Self.sceneIDSymbol))"), """
            The reopen item no longer targets the main scene by its id symbol. A hardcoded \
            string here could drift from the scene's own id and open nothing at all.
            """)
    }

    /// The title is a literal in the scene and a lookup in the menu item. That is only harmless
    /// because the two are the same text everywhere — asserted, not assumed.
    func testTheAppNameKeyIsTheSameTextInAllSixLanguages() throws {
        let root = AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources")
        let locales = ["en", "fr", "ja", "ko", "zh-Hans", "zh-Hant"]
        var values: [String: String] = [:]
        for locale in locales {
            let text = try String(contentsOf: root.appendingPathComponent("\(locale).lproj/Localizable.strings"),
                                  encoding: .utf8)
            let line = text.split(separator: "\n").first { $0.hasPrefix("\"app.name\"") }
            let value = try XCTUnwrap(line, "\(locale) has no app.name key")
                .components(separatedBy: "=").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
            values[locale] = value
        }
        XCTAssertEqual(values.count, 6, "one of the six locales did not yield a value")
        XCTAssertEqual(Set(values.values), ["SoloLedger"], """
            app.name is no longer the same text in all six languages: \(values). The scene title \
            is the literal "SoloLedger" precisely because it could not differ from the lookup; \
            if that stops being true, the scene needs a different answer, not this assertion.
            """)
    }

    // MARK: - (3) nothing lit up and inert

    func testTheNewItemGroupStillHoldsTheTransactionCommand() throws {
        let code = try requireStrippedSource("AppCommands.swift")
        XCTAssertTrue(code.contains("CommandGroup(replacing: .newItem)"),
                      "the .newItem replacement is gone; ⌘N's ownership of that slot is part of what G4 measured")
        XCTAssertTrue(code.contains(#"model.t("cmd.newTransaction")"#),
                      "the new-transaction command left the .newItem group")
        XCTAssertTrue(code.contains(#"keyboardShortcut("n", modifiers: .command)"#),
                      "⌘N is no longer bound to the new-transaction command")
    }

    func testEveryWindowActingCommandIsDisabledWithoutTheMainWindow() throws {
        let code = try requireStrippedSource("AppCommands.swift")
        XCTAssertEqual(Self.occurrences(of: Self.disableModifier, in: code), Self.windowActingCommandCount, """
            Expected exactly \(Self.windowActingCommandCount) commands guarded by \
            `\(Self.disableModifier)` (new transaction, import CSV, export CSV, the navigation \
            picker). A command that acts on the main window and is NOT in that set is enabled \
            with no window and does nothing visible — the state this round exists to remove. If \
            a command was added, decide what it does with no window and update the count.
            """)
        // The reopen item must NOT be disabled: it is the one with work to do when the window
        // is gone. Checked by shape — the shortcut and the modifier never share a line.
        for line in code.split(separator: "\n") where line.contains(Self.reopenShortcut) {
            XCTAssertFalse(line.contains(Self.disableModifier),
                           "the reopen item is disabled on the same line as its shortcut")
        }
        // `try XCTUnwrap`, not `XCTAssertEqual` + subscript. An `XCTAssert*` does not stop the
        // test, so indexing straight into the split would TRAP when the group is missing — and
        // a trap takes the whole xctest process down, so the other twelve tests in this file
        // never report at all. Measured while reverse-proving this guard: deleting the command
        // group produced `Fatal error: Index out of range` and `signal code 5` instead of one
        // red test. A guard that crashes on the very mutation it exists to catch is telling the
        // truth in the least usable possible way.
        let reopenBlock = code.components(separatedBy: "CommandGroup(after: .windowList)")
        XCTAssertEqual(reopenBlock.count, 2, "expected exactly one Window-menu command group")
        let afterGroup = try XCTUnwrap(reopenBlock.count == 2 ? reopenBlock[1] : nil,
                                       "no Window-menu command group to inspect")
        XCTAssertFalse(afterGroup.contains(Self.disableModifier), """
            The reopen command is disabled. It is the only item that must stay live while the \
            main window is closed; disabling it recreates the rejection exactly.
            """)
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: - Counterexamples

    /// The stripper is load-bearing, so it gets its own test before anything trusts it.
    func testTheCommentStripperRemovesCommentsAndKeepsCode() {
        let sample = """
        // WindowGroup mentioned in a line comment
        let kept = "WindowGroup in a string literal"
        /* WindowGroup
           mentioned in a block comment */
        let alsoKept = 1 // trailing
        """
        let stripped = Self.strippingComments(sample)
        XCTAssertEqual(Self.occurrences(of: "WindowGroup", in: stripped), 1,
                       "exactly the literal occurrence should survive; got: \(stripped)")
        XCTAssertTrue(stripped.contains("let kept"))
        XCTAssertTrue(stripped.contains("let alsoKept = 1"))
        XCTAssertFalse(stripped.contains("line comment"))
        XCTAssertFalse(stripped.contains("block comment"))
    }

    /// The specific way this guard would rot: the command deleted, its explanation left behind.
    func testAGuardBuiltOnRawTextWouldPassOnCommentsAlone() {
        let gutted = """
        struct AppCommands: Commands {
            // G4: the Window menu carries CommandGroup(after: .windowList) with
            // model.t("app.name") and .keyboardShortcut("0", modifiers: .command).
            var body: some Commands { EmptyCommands() }
        }
        """
        XCTAssertTrue(gutted.contains("CommandGroup(after: .windowList)"),
                      "a raw-text guard passes on this — that is the point of the test")
        let stripped = Self.strippingComments(gutted)
        XCTAssertFalse(stripped.contains("CommandGroup(after: .windowList)"))
        XCTAssertFalse(stripped.contains(Self.reopenTitleKey))
        XCTAssertFalse(stripped.contains(Self.reopenShortcut))
    }

    func testRevertingToWindowGroupIsDetected() {
        let reverted = Self.strippingComments("""
        var body: some Scene {
            WindowGroup { RootView() }
        }
        """)
        XCTAssertTrue(reverted.contains("WindowGroup"))
        XCTAssertFalse(reverted.contains("Window(\"SoloLedger\", id: Self.mainWindowID)"))
    }

    func testChangingTheShortcutIsDetected() {
        let moved = Self.strippingComments("""
        Button(model.t("app.name")) { openWindow(id: SoloLedgerApp.mainWindowID) }
            .keyboardShortcut("1", modifiers: .command)
        """)
        XCTAssertTrue(moved.contains(Self.reopenTitleKey), "the title survives; only the shortcut moved")
        XCTAssertFalse(moved.contains(Self.reopenShortcut))
    }

    func testDroppingADisabledModifierIsDetected() {
        let short = Self.strippingComments("""
        Button(a) { }.disabled(!model.mainWindowIsOpen)
        Button(b) { }.disabled(!model.mainWindowIsOpen)
        Button(c) { }
        """)
        XCTAssertEqual(Self.occurrences(of: Self.disableModifier, in: short), 2)
        XCTAssertNotEqual(Self.occurrences(of: Self.disableModifier, in: short),
                          Self.windowActingCommandCount,
                          "three commands with only two guards must not satisfy the count")
    }

    func testDisablingTheReopenItemIsDetected() {
        let wrong = Self.strippingComments("""
        CommandGroup(after: .windowList) {
            Button(model.t("app.name")) { openWindow(id: SoloLedgerApp.mainWindowID) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.mainWindowIsOpen)
        }
        """)
        let parts = wrong.components(separatedBy: "CommandGroup(after: .windowList)")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[1].contains(Self.disableModifier),
                      "this is the shape the real assertion must reject")
    }

    func testAnEmptySourceYieldsNoMatchesRatherThanASilentPass() {
        XCTAssertEqual(Self.strippingComments(""), "")
        XCTAssertEqual(Self.occurrences(of: Self.disableModifier, in: ""), 0)
        XCTAssertEqual(Self.occurrences(of: "", in: "anything"), 0,
                       "an empty needle must not report a match on every position")
    }
}
