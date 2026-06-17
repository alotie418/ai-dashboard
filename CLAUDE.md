# CLAUDE.md

## Project direction

This project is a local-first Electron desktop application for accounting, bookkeeping, invoicing, inventory, and business operations management.

The target users are small businesses, solo operators, cross-border sellers, and lightweight business owners who need a local desktop tool to manage:

* Sales and purchases
* Products, inventory, and cost tracking
* Customers and suppliers
* Invoices, quotations, and business documents
* Receivables and payables
* Payment status tracking
* Local SQLite data storage
* Local backup and restore
* CSV import/export
* Business dashboards
* Financial summaries and management reports
* Multi-language UI
* Optional future e-commerce platform data import/sync

The product should be positioned as a business bookkeeping and financial analysis assistant, not as an official tax filing, audit, or statutory accounting compliance system.

## Product boundary

This app is not intended to replace a licensed accountant, tax advisor, auditor, or statutory compliance system.

Do not present estimated reports, simplified tax calculations, or incomplete accounting modules as official tax filings, audit-ready statements, or legally compliant reports.

Complex accounting and tax outputs should be treated as:

* Business reference
* Management analysis
* Estimated summary
* User-configurable helper output
* Subject to professional review when used for tax, audit, or legal reporting

When a feature is not fully implemented, the UI should say so clearly. Do not show placeholder values as if they are official financial metrics.

Examples:

* If the balance sheet is not implemented, do not show formal debt ratio or current ratio cards.
* If cash flow is not implemented, do not show fake or hardcoded cash flow metrics.
* If a value is an estimate, label it as an estimate.
* If a calculation depends on accounting policy, do not silently choose a policy without documentation.

## Accounting calculation principles

Claude may safely help with:

* Fixing obvious UI display bugs
* Fixing localization issues
* Fixing raw enum display such as UNPAID, PAID, PARTIAL
* Fixing empty-state display such as showing N/A instead of misleading 100%
* Fixing misleading labels
* Fixing error messages
* Fixing missing fields in handlers when the schema already supports them
* Adding tests for existing behavior
* Improving validation and guard scripts
* Improving code clarity without changing accounting meaning

Claude must not casually change core accounting formulas.

Do not modify the following without explicit user approval and a prior read-only analysis:

* electron/reports/*
* accounting profiles
* tax rate defaults
* income tax formulas
* VAT/GST/sales tax formulas
* COGS logic
* _expenseSplit
* inventory cost formulas
* weighted average cost logic
* shipping cost treatment
* asset/liability calculations
* cash flow formulas
* balance sheet formulas
* statutory report mappings
* schema or migrations related to accounting meaning

If an issue involves accounting judgment, tax law, national accounting standards, or industry-specific cost treatment, do not guess. Mark it as requiring user/accountant confirmation.

The preferred rule is:

AI may implement confirmed formulas, but AI must not invent accounting policy.

## Multi-country accounting scope

The app may support multiple UI languages and multiple accounting profiles, but this does not mean it is automatically compliant with every country or region.

Supported accounting profiles should be treated as configurable business-analysis profiles unless professionally reviewed.

Do not claim or imply that the app automatically satisfies official reporting requirements for:

* China
* United States
* Japan
* European Union
* South Korea
* Taiwan
* Any other country or region

When adding or changing country-specific accounting behavior, first do read-only analysis and identify whether the change is:

1. A clear software bug
2. A UI/display issue
3. A configurable business assumption
4. A tax/accounting policy decision requiring professional review

Only category 1 and category 2 should be fixed directly.

## E-commerce platform integration direction

Future versions may support optional marketplace and e-commerce platform integrations.

Possible platforms include:

* Amazon
* Temu
* eBay
* Shopee
* Shopify
* TikTok Shop
* Taobao / Tmall
* JD
* Pinduoduo
* 1688
* Other marketplaces

These integrations should be designed as data import and synchronization helpers, not as automatic tax compliance engines.

Allowed future integration scope:

* Orders
* Order items
* Refunds
* Returns
* Platform fees
* Advertising fees
* Shipping fees
* Payouts
* Settlement reports
* Products and SKUs
* Inventory movement
* Platform invoices
* Customer/buyer records where legally and technically available

Preferred architecture:

* Each platform connector converts platform-specific data into internal normalized records.
* The accounting app should consume internal normalized records, not platform-specific raw structures everywhere.
* Platform integrations should be optional.
* Credentials and API keys must be stored securely.
* No platform integration should bypass local-first data ownership principles.

Do not market marketplace integrations as automatic VAT/GST/sales-tax filing or official compliance unless reviewed by qualified professionals.

## Architecture boundary

This is a local Electron application.

The current target architecture is:

* Electron desktop app
* Local SQLite database
* Local filesystem attachments
* Electron IPC
* Local api:request routing
* No required cloud backend for core app usage

Do not restore retired web/cloud architecture unless explicitly requested.

Do not reintroduce:

* Web fallback
* Cloudflare Worker API
* Cloudflare D1
* Cloudflare KV
* Cloudflare Pages dependency
* Google Cloud Run dependency
* Remote auth gate
* LoginPage requirement for local usage
* Required hosted backend for local accounting features

The app should remain usable as a local desktop app.

## PR workflow

Use small, focused PRs.

Each PR should solve one clearly defined problem.

Do not mix unrelated changes such as:

* UI wording and accounting formulas
* Schema migrations and display fixes
* CI changes and business logic
* Electron IPC changes and report formula changes
* i18n cleanup and tax calculation changes

Recommended workflow:

1. Start with read-only analysis.
2. Identify exact files and risk level.
3. Ask for confirmation before implementation when risk is medium or high.
4. Create a focused branch.
5. Implement only the approved scope.
6. Run the relevant verification commands.
7. Commit and push.
8. Create a PR.
9. Do not merge unless explicitly instructed.

When finishing a task, report:

* Branch name
* Commit hash
* PR link and number
* Files changed
* Validation commands and results
* Whether merge was performed
* Whether any out-of-scope files were changed

## Validation commands

For frontend, UI, display, and i18n changes, usually run:

```
npm run check:all
npm run typecheck
npm run build
npm run test:locale-ui
```

For handler/backend route changes, usually run:

```
npm run check:handlers
npm run check:all
npm run typecheck
npm run build
```

If better-sqlite3 ABI prevents local handler tests from running, use the established local flow:

```
npm rebuild better-sqlite3
npm run check:handlers
npm run electron:rebuild
```

For Electron IPC, attachment, filesystem, or real main-process changes, run:

```
npm run test:electron
```

Do not run test:electron unnecessarily for pure UI or pure i18n changes.

## Testing and quality principles

Prefer guard tests for previously fixed bugs.

Important existing safety themes:

* Locale matrix should not regress.
* Raw i18n keys should not leak.
* TypeScript should pass tsc --noEmit.
* Handler round-trip tests should protect local SQLite routes.
* Electron e2e should protect real IPC/filesystem behavior when relevant.
* Error messages should be user-actionable and localized.
* UI should not display raw backend enum values or technical error strings.

## User communication preference

The user prefers Chinese explanations.

Responses should be direct and operational.

When giving implementation instructions, provide concrete commands or a copy-paste prompt.

When a task is risky, clearly state:

* What is safe to change
* What must not be changed
* What needs accountant/user confirmation
* What tests should be run

Avoid vague advice.

## Current strategic rule

Before packaging, signing, notarization, or public release, prioritize:

1. Clear product positioning
2. Stable local desktop behavior
3. No misleading financial displays
4. Clean localization
5. Reliable local data handling
6. Backup/restore safety
7. Focused business workflows
8. Guard tests for known regressions

Do not rush into packaging if core accounting displays, UI clarity, or local data safety still need cleanup.
