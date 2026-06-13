# Provider logos (BYOK cards)

Drop each AI provider's **official** logo here to replace the abstract FontAwesome icon in
Settings → AI Providers (and the onboarding wizard). Files are bundled at build time via Vite
`import.meta.glob` (base-relative + hashed → works offline in the Electron/DMG build). **No remote
/ CDN loading, no base64 in code.**

## Naming (file basename = provider id)

| file | provider |
|------|----------|
| `anthropic.svg` | Claude / Anthropic |
| `openai.svg`    | ChatGPT / OpenAI |
| `gemini.svg`    | Gemini / Google |
| `deepseek.svg`  | DeepSeek |
| `qwen.svg`      | 通义千问 / Qwen |
| `kimi.svg`      | Kimi / 月之暗面 |
| `glm.svg`       | GLM / 智谱 AI |
| `doubao.svg`    | 豆包 / 火山方舟 |

- Prefer **SVG**; if no good SVG exists, use `.png` or `.webp` with the same basename.
- Rendered at a uniform size (24×24 in the settings card, 20×20 in onboarding) via CSS — the source
  file size doesn't matter.
- **A provider with no logo file here automatically falls back to its FontAwesome icon** — so this
  directory may be empty and the app still works.
- These are third-party trademarks; obtain them from each vendor's official brand/press kit.
