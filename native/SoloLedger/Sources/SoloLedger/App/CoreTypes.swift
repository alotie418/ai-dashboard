import SoloLedgerCore

// SwiftUI also declares a `Transaction` type (animation transactions), and other
// frameworks declare `Category`. These module-scoped typealiases make the
// unqualified names resolve to our domain models throughout the app target
// (a local declaration shadows names imported from other modules).
typealias Transaction = SoloLedgerCore.Transaction
typealias Category = SoloLedgerCore.Category
