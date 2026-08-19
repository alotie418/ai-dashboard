#!/usr/bin/env node
// D-5 / Q7-b —— 导出产物黄金的再生成校验。
//
// 黄金是**对面**的输出，不是原生的快照：`native/SoloLedger/Tests/Fixtures/documentHtml/*.html`
// 由 node 直接 import `components/documentPdf.ts` 生成，Swift 侧的 `DocumentExportTests` 拿它当
// 验收线。所以这里要证明的只有一件事：**committed 的那份仍然是真模板此刻会吐出来的那份**。
// 若 Electron 侧的模板改了而黄金没跟着改，Swift 的比对就会去追一份过期的真值，红也红得没道理。
//
// 与报表黄金**刻意分开**：那批在 `Tests/SoloLedgerCoreTests/Fixtures/reports/goldens` 下，由
// `scripts/check-golden-changes.mjs` 的 `Allowed-Golden-Changes` 白名单守着（改动必须在 commit
// trailer 里先声明）。本批不进那个目录、不走那个通道，因为两者的性质不同：报表黄金是**引擎的真值**，
// 动它等于改口径；这一批是**对面模板的当前形态**，它变了就该跟着变，需要的是「必须一起变」而不是
// 「不许变」。
//
// LC_ALL 必须是 en_US.UTF-8：`formatMoney` 末端是 `toLocaleString(undefined, …)`，跟宿主区域走。
// 生成器自己会拒绝非 en-US 的宿主，这里显式设一遍，免得校验因为跑它的人的语言环境而红。
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { GOLDENS_DIR, LANGUAGES, FIXTURE, GENERATED_AT, renderAll }
  from '../native/SoloLedger/Tests/Fixtures/make-document-html-goldens.mjs';

const REGENERATE = 'npm run gen:document-html-goldens';
let failures = 0;
const fail = (m) => { console.error(`  ✗ ${m}`); failures += 1; };

const rendered = renderAll();
for (const [lang] of LANGUAGES) {
  const path = join(GOLDENS_DIR, `${lang}.html`);
  if (!existsSync(path)) { fail(`${lang}.html is missing — run ${REGENERATE}`); continue; }
  const committed = readFileSync(path, 'utf8');
  const fresh = rendered.get(lang);
  if (committed === fresh) { console.log(`  ✓ ${lang}.html (${committed.length} chars)`); continue; }
  const a = committed.split('\n'), b = fresh.split('\n');
  const i = a.findIndex((line, idx) => line !== b[idx]);
  fail(`${lang}.html no longer matches the template it came from. First difference at line ${i + 1}:\n`
     + `      committed: ${String(a[i]).slice(0, 160)}\n`
     + `      template : ${String(b[i] ?? '<missing>').slice(0, 160)}\n`
     + `    The Swift parity test measures against this file, so regenerate it (${REGENERATE}) `
     + 'and read the diff before committing — a change here is a change in the other app.');
}

// The fixture the Swift side decodes has to be the fixture this generator renders.
const fixturePath = join(GOLDENS_DIR, 'fixture.json');
if (!existsSync(fixturePath)) fail(`fixture.json is missing — run ${REGENERATE}`);
else {
  const committed = readFileSync(fixturePath, 'utf8');
  const fresh = JSON.stringify({ generatedAt: GENERATED_AT, document: FIXTURE }, null, 2) + '\n';
  if (committed === fresh) console.log('  ✓ fixture.json');
  else fail(`fixture.json is stale — run ${REGENERATE}. The Swift test decodes this file, so a `
          + 'golden rendered from a different document would be compared against the wrong input.');
}

if (failures > 0) {
  console.error(`\n✗ document-html goldens: ${failures} problem(s)`);
  process.exitCode = 1;
} else {
  console.log(`✓ document-html goldens: ${LANGUAGES.length} languages + fixture reproduce exactly`);
}
