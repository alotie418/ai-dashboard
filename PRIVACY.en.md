# Privacy Notice

> Last updated: 2026-07-09 | Applies to: SoloLedger v1.0.x (local desktop edition)
>
> 中文版 / Chinese: [PRIVACY.md](PRIVACY.md)

This document explains, in plain language, how the SoloLedger desktop application handles your data. It describes the actual behavior of the current version. **It is not legal advice, nor any kind of compliance certification.** SoloLedger is a business bookkeeping and management-analysis tool; it does not replace an accountant, tax advisor, or statutory compliance system.

If the application's behavior changes in a future version, this notice will be updated accordingly; please refer to the notice that corresponds to the version you are using.

---

## 1. Core principle: Local-first

SoloLedger is a **local-first** desktop application. All of your business data (purchases, sales, inventory, invoices, business documents, receivables/payables, categories, reports, etc.) is stored in a **local SQLite database file on your own computer**:

- Database file: `sololedger.db`, under the application's `userData` directory (on macOS, typically in the app-specific directory under `~/Library/Application Support/`).
- **No cloud account, no SoloLedger server-side storage**: core bookkeeping works without sign-in and without a network connection.
- **SoloLedger does not operate a cloud service for collecting business records**, and there is no developer-operated account system. Your business records stay on your device by default.

## 2. How your API keys are stored

SoloLedger **does not include any built-in AI backend**; it uses a BYOK (bring-your-own-key) model. The provider API keys you enter are:

- encrypted using the operating system's **`safeStorage` (the OS keystore; on macOS, the Keychain)** and written to the local database as ciphertext;
- decrypted **only within the main process, on demand**, to make an AI request; **the interface (renderer) cannot obtain the plaintext**;
- after you delete a key, the corresponding provider is disabled immediately, while the business data you have already entered is retained;
- if the operating system's encryption capability is unavailable, the application cannot save the key (and the corresponding AI features cannot be used).

> Note: This is **on-device local encryption** intended to protect the key on your disk. It is **not end-to-end encryption**, and it does not imply any additional guarantee about data while it is transmitted over the network. No security mechanism can guarantee absolute protection; please also maintain your own device security and backups.

## 3. Network behavior at a glance

- **Core bookkeeping is fully offline**: interface static assets are bundled and self-hosted at build time, with no dependency on any CDN or remote resource at runtime.
- **Other than when you open an external link or actively use an AI feature, the current version does not include any background networking, telemetry, crash reporting, automatic updates, or phone-home behavior.**
- External links inside the application are opened in your default browser.

## 4. AI features and data transmission

Whether to use AI features is entirely up to you. If you do not configure any key and do not use AI features, bookkeeping still works offline, and your business data does not leave your machine as a result. When you use the AI features below, the request is sent **directly from your computer to the third-party provider you have chosen** (e.g., Anthropic / OpenAI / Google / DeepSeek / Alibaba Cloud Qwen / Moonshot Kimi / Zhipu GLM / ByteDance Volcano Doubao); **SoloLedger does not operate any relay or proxy server, and the request does not pass through any SoloLedger server.** What each feature actually sends:

- **AI assistant chat**: sends your question, along with **your own bookkeeping data that the assistant queries** in order to answer. The assistant can only call **read-only** query tools (it cannot add, modify, or delete entries), but its query results are sent to the provider as part of the request — and this **may include record-level details**, such as dates, amounts, counterparty (customer/supplier) names, invoice status, and various summary figures.
- **Dashboard AI briefing**: sends the dashboard's **aggregated business figures** (for example revenue, gross/net margin, inventory, purchase/sales totals, and cumulative and estimated VAT figures). It does not make this request when the ledger is empty.
- **Invoice/document OCR**: sends the **document image** you provide for recognition (see Section 5).

> The year-over-year / month-over-month / price-index metrics on the "Data Analysis" page are computed **locally; they do not call AI and do not send any data**.

## 5. File handling (OCR / PDF / CSV / xlsx)

- **Invoice/document OCR**: the document image you provide is sent as an image to the currently configured OCR-capable provider (using that provider's key) for recognition. The result **first enters a preview, and is only filled into the form after you confirm it; it is not posted to the books automatically**.
- **PDF**: a PDF is rasterized into an image (first page) **locally** by `pdf.js`, a process that runs on your computer; **however, if you use that PDF for OCR, the rasterized image is likewise sent to the provider above**.
- **CSV / Excel (xlsx)**: import parsing and export are both performed **locally, without going over the network**; an exported CSV is saved to a local location you choose (by default, the system "Documents" directory).

## 6. Optional e-commerce integrations (Beta)

SoloLedger includes **optional** e-commerce order-import integrations (currently Shopify and WooCommerce, shipped as Beta). They are **off unless you actively configure them** with credentials for a third-party store that you control:

- Store credentials you enter are encrypted with the operating system's **`safeStorage` (on macOS, the Keychain)** and stored locally as ciphertext, decrypted only in the main process; the interface never sees them.
- Order pulls are sent **directly from your computer to the store platform you configured**; SoloLedger does not operate any relay server.
- Imported orders are staged locally and written to your books only after you explicitly confirm them.
- **Buyer personal details (names, emails, phone numbers, addresses) are never persisted** to the local database, and raw platform payloads are not stored.
- How the third-party platform (e.g., Shopify or your WooCommerce host) handles data on its side is governed by that platform's own terms and privacy policy.

## 7. Telemetry, logs, and crash reporting

The **current version does not include any** of the following:

- no telemetry or usage analytics;
- no crash reporting;
- no automatic updates or background "call-home" checks (auto-update / phone-home);
- no log files written to disk, and no logs uploaded anywhere.

Diagnostic information is only printed to the development/console output; it is not written to disk and is not transmitted.

## 8. Backup and restore

- A **manual backup** exports a **folder bundle** containing the database `sololedger.db` **as well as the invoice attachments `attachments/docs`** (exported by default to the system "Documents" directory).
- **Automatic backup**: before a destructive operation such as a migration or a restore, the application creates a rolling snapshot in the local `userData/backups` directory (using verification, atomic replacement, and similar measures to reduce the risk of corruption).
- When restoring an older backup, attachments are merged back into `userData/attachments/docs` on an "add-only" basis.
- All backups are **local files**, kept and moved by you; please protect backups that contain business data.

## 9. Third-party AI providers

SoloLedger acts only as a local client between you and the provider you choose. Content you send through AI features is sent to the provider you have selected; currently configurable providers include:

- Claude (Anthropic)
- ChatGPT (OpenAI)
- Gemini (Google)
- DeepSeek
- Qwen (Alibaba Cloud)
- Kimi (Moonshot AI)
- GLM (Zhipu AI)
- Doubao (ByteDance / Volcano Engine)

**How these providers handle the content you send — including data retention, whether it is used for model training, and logging — is determined by each provider's own privacy policy and data-usage terms, and is outside SoloLedger's control.** Before using a given provider, **please refer to and review that provider's official privacy policy and data-usage terms yourself.**

## 10. Your control over your data

- You can delete any key at any time under "Settings → AI Providers" (deletion disables that provider immediately; your business data is retained).
- All local data lives in the `userData` directory; deleting `sololedger.db` (along with `attachments` and `backups`) or uninstalling the application removes the data from your machine (back up first if needed).
- Whether content already sent to a third-party provider can be recalled or deleted depends on that provider's policy; please ask the provider.

## 11. No sale of your data

**SoloLedger does not sell your data.** The developer has no access to your business records — they live on your device (see Section 1) — and SoloLedger does not operate a cloud service for collecting business records.

## 12. Support and contact

For questions about this notice or the application, please use the public support channel (kept reachable independently of this repository's visibility):

- **Support page**: <https://alotie418.github.io/sololedger-legal/support/>
- **GitHub Issues**: <https://github.com/alotie418/sololedger-legal/issues>

Please do **not** include API keys, store credentials, or sensitive business records in public issue reports.

> The publicly hosted copy of this notice lives at <https://alotie418.github.io/sololedger-legal/privacy/>. When this file changes, update that copy as well (see `docs/RELEASE.md`).

## 13. Changes to this notice

This notice describes the behavior of a specific version and may change as the application is updated. Significant changes will update the date and applicable version at the top of this file.

---

*Related: [README](README.md) | [Product roadmap](docs/ROADMAP-to-v1.md). This notice is a product-usage reference, not legal advice.*
