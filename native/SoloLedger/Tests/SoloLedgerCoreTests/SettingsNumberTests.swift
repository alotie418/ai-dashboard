import XCTest
@testable import SoloLedgerCore

/// The numeric settings accessors must stay byte-compatible with the Electron app,
/// which writes these keys with `JSON.stringify` — and, for `vat_rate`, writes them
/// from two different screens with two different JSON types (a number from the
/// accounting section and the onboarding wizard, a string from the tax settings
/// screen). Reading only one form would silently drop a real user's configured rate.
final class SettingsNumberTests: LedgerTestCase {

    func testReadsAJSONNumber() throws {
        let store = try makeStore()
        try store.settings.setNumber(13, for: SettingsStore.Key.vatRate)
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "13",
                       "integral values must be written as JSON.stringify does — no trailing .0")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.vatRate), 13)
    }

    func testReadsAJSONStringHoldingANumber() throws {
        let store = try makeStore()
        // Exactly what components/SettingsPage.tsx persists.
        try store.settings.setString("13", for: SettingsStore.Key.vatRate)
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "\"13\"")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.vatRate), 13)
    }

    func testFractionalValueRoundTrips() throws {
        let store = try makeStore()
        try store.settings.setNumber(23.2, for: SettingsStore.Key.incomeTaxRate)
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.incomeTaxRate), "23.2")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.incomeTaxRate), 23.2)
    }

    func testAbsentKeyIsNil() throws {
        XCTAssertNil(try makeStore().settings.number(SettingsStore.Key.surchargeRate))
    }

    func testNonNumericAndBooleanValuesReadAsNil() throws {
        let store = try makeStore()
        try store.settings.setString("13%", for: SettingsStore.Key.vatRate)   // e2e fixtures model this
        XCTAssertNil(try store.settings.number(SettingsStore.Key.vatRate))
        try store.settings.setString("", for: SettingsStore.Key.vatRate)
        XCTAssertNil(try store.settings.number(SettingsStore.Key.vatRate))
        try store.settings.setBool(true, for: SettingsStore.Key.vatRate)
        XCTAssertNil(try store.settings.number(SettingsStore.Key.vatRate),
                     "a boolean must not decode as 1 — JSONSerialization would happily hand back an NSNumber")
    }

    func testNonFiniteValuesAreRefusedNotWritten() throws {
        let store = try makeStore()
        try store.settings.setNumber(25, for: SettingsStore.Key.incomeTaxRate)
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try store.settings.setNumber(bad, for: SettingsStore.Key.incomeTaxRate))
        }
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.incomeTaxRate), 25,
                       "a refused write must leave the previous value intact")
    }

    func testReportParametersReadsAllFourKeysAndKeepsAbsenceAbsent() throws {
        let store = try makeStore()
        try store.settings.setNumber(9, for: SettingsStore.Key.vatRate)
        try store.settings.setNumber(120_000, for: SettingsStore.Key.adminExpenseAnnual)
        let stored = try store.settings.reportParameters()
        XCTAssertEqual(stored.vatRate, 9)
        XCTAssertEqual(stored.adminExpenseAnnual, 120_000)
        XCTAssertNil(stored.surchargeRate)
        XCTAssertNil(stored.incomeTaxRate)
    }

    func testRemoveClearsTheSettingBackToAbsent() throws {
        // "Unset" must be reachable: clearing the field deletes the row rather than
        // writing a 0 the user never chose, so the report engines resume using their
        // own fallback for that key.
        let store = try makeStore()
        try store.settings.setNumber(9, for: SettingsStore.Key.vatRate)
        try store.settings.remove(SettingsStore.Key.vatRate)
        XCTAssertNil(try store.settings.number(SettingsStore.Key.vatRate))
        XCTAssertNil(try store.settings.rawValue(SettingsStore.Key.vatRate), "the row itself must be gone")
        XCTAssertNoThrow(try store.settings.remove(SettingsStore.Key.vatRate), "removing an absent key is a no-op")
    }

    func testRegimeSwitchWritesAllFiveKeysAtomically() throws {
        let store = try makeStore()
        try store.settings.setNumber(3, for: SettingsStore.Key.vatRate)      // small-scale taxpayer
        try store.settings.setNumber(120_000, for: SettingsStore.Key.adminExpenseAnnual)

        try store.settings.applyRegimeSwitch(AccountingProfile.jp)

        XCTAssertEqual(try store.settings.accountingLocale(), .JP)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.vatRate), 10)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.surchargeRate), 0)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.incomeTaxRate), 23.2)
        XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), "JPY")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.adminExpenseAnnual), 120_000,
                       "the annual admin expense is not part of the regime cascade")
    }

    func testRegimeSwitchWritesTheCurrencyElectronWouldRead() throws {
        // components/AccountingSection.tsx applyProfile saves currency alongside the
        // rates; electron/reports/index.js reads it and every engine echoes it into the
        // report, so omitting it would label a switched regime with the stale currency.
        let store = try makeStore()
        for profile in [AccountingProfile.cn, .us, .jp, .eu, .kr, .tw] {
            try store.settings.applyRegimeSwitch(profile)
            XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), profile.currency,
                           "\(profile.locale)")
            XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.currency), "\"\(profile.currency)\"",
                           "must be JSON.stringify-shaped for the Electron reader")
        }
    }

    func testNegativeAndLargeValuesRoundTripVerbatim() throws {
        let store = try makeStore()
        // No range policy is invented here: Electron stores whatever the user typed.
        try store.settings.setNumber(-5, for: SettingsStore.Key.surchargeRate)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.surchargeRate), -5)
        try store.settings.setNumber(1_234_567.89, for: SettingsStore.Key.adminExpenseAnnual)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.adminExpenseAnnual), 1_234_567.89)
    }
}
