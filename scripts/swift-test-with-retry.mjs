#!/usr/bin/env node
// Runs the native SoloLedgerCore test suite, and retries exactly ONE named test —
// the flake tracked in issue #400 — exactly once, with the recurrence RECORDED
// before the job is allowed to go green.
//
// Why this exists
// ---------------
// `HardenedActiveOpenTests.testPostOpenUnlinkCaughtByHasMoved` fails intermittently
// on CI: `SQLITE_FCNTL_HAS_MOVED` returns `SQLITE_IOERR_VNODE` (rc 6922) instead of
// reporting the unlink. Five occurrences are on the issue's ledger, the last of them
// a same-image/same-window red-vs-green pair, and the escalation clause on that issue
// — "if the recurrence rate starts hurting the merge queue, escalate to job-level
// single-test retry + mandatory accounting" — is what this script implements.
//
// The rule it must not break is the OTHER sentence on that issue: **an auto-rerun that
// leaves no trace is never allowed.** So this is not a retry with logging bolted on;
// it is accounting with a retry attached. `orchestrate()` can only return 0 through a
// path that has already awaited `record()`, and `record()` throws unless all three of
// its channels succeeded. A retry that passes but cannot be recorded fails the job.
//
// What it deliberately does NOT do
// --------------------------------
// * It does not touch the test or the product. Whether the right end-state is a
//   weaker test assumption or a bounded retry inside `MigrationBootDriver` is still
//   an open question on #400; this script takes no position on it.
// * It does not retry any other failure shape. Two failures, a different single
//   failure, a crash (a run that prints no root summary), or an "unexpected" failure
//   count all fall straight through to a red job.
// * It does not retry twice. One retry; still red means red.
// * It does not retry OFF CI, because off CI there is nowhere to record it. Locally
//   the flake shape is reported and the original exit code is returned unchanged.
// * It does not record a retry that FAILED. The job is red in that case and a human
//   is already involved; #400's manual ledger discipline covers it.
// * On a pull request from a FORK, `GITHUB_TOKEN` is read-only whatever the job's
//   `permissions:` block says, so the issue comment would fail and — by design — the
//   job would go red instead of silently re-running. This repository has never taken
//   a fork PR; the note is here so the behaviour is a known one rather than a surprise.
//
// Usage: node scripts/swift-test-with-retry.mjs
//   Locally this machine needs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
//   (xcode-select points at the CLT); CI's macOS image needs nothing.
import { spawn } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/// The invocation this script replaces in `.github/workflows/ci.yml`. `SCRATCH_PATH`
/// must stay equal to that workflow's `SWIFT_WARNING_SCRATCH_PATH`, or the test run
/// stops reusing the warning gate's compile and pays for a second full build —
/// `FlakeRetryGateGuardTests` pins the two together.
export const PACKAGE_PATH = 'native/SoloLedger';
export const SCRATCH_PATH = '.swift-gate-build';

/// The one test this script is allowed to retry, in the three spellings that are
/// needed: XCTest prints `Module.Suite method`, `--filter` takes a regex, and humans
/// read `Suite.method`.
export const FLAKY_MODULE = 'SoloLedgerCoreTests';
export const FLAKY_SUITE = 'HardenedActiveOpenTests';
export const FLAKY_METHOD = 'testPostOpenUnlinkCaughtByHasMoved';
export const FLAKY_TEST = `${FLAKY_SUITE}.${FLAKY_METHOD}`;
export const FLAKY_FILTER = `${FLAKY_MODULE}\\.${FLAKY_SUITE}/${FLAKY_METHOD}$`;

export const ISSUE_NUMBER = 400;

/// The two names XCTest gives the outermost suite: `All tests` for a whole run,
/// `Selected tests` when `--filter` is in play. Measured, both of them.
export const ROOT_SUITES = ['All tests', 'Selected tests'];

// --- reading `swift test` output --------------------------------------------
//
// Shapes below are quoted from real runs: the failing one is job 95182149772
// (run 31954181406 attempt 1, ledger row 5), the passing and filtered ones are local.
//
//   Test Case '-[SoloLedgerCoreTests.HardenedActiveOpenTests testPostOpen…]' failed (0.310 seconds).
//   /Users/runner/…/HardenedActiveOpenTests.swift:258: error: -[SoloLedgerCoreTests.HardenedActiveOpenTests testPostOpen…] : failed - expected identity(moved), got hasMovedFailed(fileControlRC: 6922, systemErrno: 0)
//   Test Suite 'All tests' failed at 2026-08-16 15:01:09.384.
//   	 Executed 1288 tests, with 1 failure (0 unexpected) in 55.824 (56.100) seconds
//
// Note the singular/plural swings: "1 test" / "1 failure" against "1288 tests" /
// "0 failures". Every count below is read as a number, never inferred from wording.

const CASE_RE = /^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed)\b/;
const SUITE_RE = /^Test Suite '(.+)' (passed|failed) at /;
const SUMMARY_RE = /^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)/;
const ERROR_RE = /\berror: -\[(\w+)\.(\w+) (\w+)\] : (.*)$/;

export function parseSwiftTestOutput(text) {
  const failed = [];
  const passed = [];
  const summaries = [];
  const errors = [];
  let lastClosedSuite = null;

  for (const raw of String(text ?? '').split('\n')) {
    const line = raw.replace(/\r$/, '');

    const testCase = CASE_RE.exec(line);
    if (testCase) {
      const name = `${testCase[2]}.${testCase[3]}`;
      const bucket = testCase[4] === 'failed' ? failed : passed;
      if (!bucket.includes(name)) bucket.push(name);
      continue;
    }

    const suite = SUITE_RE.exec(line);
    if (suite) {
      lastClosedSuite = suite[1];
      continue;
    }

    // A summary always belongs to the suite whose closing line precedes it.
    const summary = SUMMARY_RE.exec(line);
    if (summary) {
      summaries.push({
        suite: lastClosedSuite,
        executed: Number(summary[1]),
        failures: Number(summary[2]),
        unexpected: Number(summary[3]),
      });
      lastClosedSuite = null;
      continue;
    }

    const error = ERROR_RE.exec(line);
    if (error) errors.push({ test: `${error[2]}.${error[3]}`, message: error[4].trim() });
  }

  return { failed, passed, summaries, errors };
}

/// The summary for the whole run. Taken as the LAST root-suite summary, because that
/// is the one XCTest prints after every nested suite has closed.
export function rootSummary(parsed) {
  const roots = parsed.summaries.filter((s) => ROOT_SUITES.includes(s.suite));
  return roots.length ? roots[roots.length - 1] : null;
}

/// The failure text for the flaky test, and the `fileControlRC` inside it if there is
/// one. The rc is ledger detail, not a trigger condition: the retry is decided by the
/// test's NAME, so a recurrence that reports some other rc is still recorded rather
/// than quietly reclassified.
export function failureDetail(parsed) {
  const entry = parsed.errors.find((e) => e.test === FLAKY_TEST) ?? null;
  const message = entry ? entry.message : null;
  const rc = message ? /fileControlRC:\s*(-?\d+)/.exec(message) : null;
  return { message, rc: rc ? Number(rc[1]) : null };
}

// --- the decision -----------------------------------------------------------

/// Retry only when the first run failed and the ONLY thing that failed was the known
/// flake. Every other reading is a red job.
///
/// The summary is checked as well as the names, and both have to agree. A run that
/// dies without printing a root summary — a crash, an OOM, a runner cut off — can
/// leave a single `failed` line as the last thing in the log, and "the last line says
/// it was our flake" must not be enough to re-run the suite and call it green.
export function decideRetry(parsed, exitCode) {
  if (exitCode === 0) return { retry: false, reason: 'the first run passed' };

  if (parsed.failed.length !== 1) {
    const names = parsed.failed.length ? parsed.failed.join(', ') : 'none parsed';
    return {
      retry: false,
      reason: `${parsed.failed.length} distinct test(s) failed (${names}); ` +
              `only a lone ${FLAKY_TEST} is retried`,
    };
  }
  if (parsed.failed[0] !== FLAKY_TEST) {
    return { retry: false, reason: `the failure is ${parsed.failed[0]}, not ${FLAKY_TEST}` };
  }

  const root = rootSummary(parsed);
  if (!root) {
    return {
      retry: false,
      reason: 'no root test-suite summary was printed, so the run did not finish normally ' +
              '— a failure that is only visible as a dangling line is not a known flake',
    };
  }
  if (root.failures !== 1) {
    return { retry: false, reason: `the run summary reports ${root.failures} failures, not 1` };
  }
  if (root.unexpected !== 0) {
    return {
      retry: false,
      reason: `the run summary reports ${root.unexpected} unexpected failure(s); ` +
              'the tracked flake is an assertion failure, and a crash-shaped one is a different animal',
    };
  }
  return { retry: true, reason: `the only failure is the known flake ${FLAKY_TEST} (issue #${ISSUE_NUMBER})` };
}

/// A passing retry has to be shown, not assumed. Measured: `swift test --filter` with
/// a pattern that matches nothing exits **0** and prints `Executed 0 tests` — so a
/// typo in the filter would turn this whole mechanism into an unconditional green.
/// Hence a positive assertion that this exact test ran and passed, on top of the
/// exit code and the count.
export function verifyRetry(parsed, exitCode) {
  if (exitCode !== 0) return { ok: false, reason: `the retry exited ${exitCode}` };

  const root = rootSummary(parsed);
  if (!root) return { ok: false, reason: 'the retry printed no root test-suite summary' };
  if (root.executed !== 1) {
    return {
      ok: false,
      reason: `the retry executed ${root.executed} tests, expected exactly 1 — a --filter that ` +
              'matches nothing exits 0 with "Executed 0 tests", which must never read as a pass',
    };
  }
  if (root.failures !== 0 || root.unexpected !== 0) {
    return { ok: false, reason: `the retry summary reports ${root.failures} failures (${root.unexpected} unexpected)` };
  }
  if (!parsed.passed.includes(FLAKY_TEST)) {
    return { ok: false, reason: `the retry never reported ${FLAKY_TEST} as passed` };
  }
  return { ok: true, reason: `${FLAKY_TEST} passed on the retry` };
}

// --- accounting -------------------------------------------------------------

/// The ledger entry, as markdown. Pure, so its five required fields — date, image and
/// version, rc, run URL, and the words that say a job-internal retry passed — can be
/// asserted without a network.
export function ledgerComment({ env = {}, detail, firstSummary, retrySummary, date }) {
  const server = env.GITHUB_SERVER_URL || 'https://github.com';
  const repo = env.GITHUB_REPOSITORY || '';
  const runId = env.GITHUB_RUN_ID || '';
  const attempt = env.GITHUB_RUN_ATTEMPT;
  const runUrl = runId
    ? `${server}/${repo}/actions/runs/${runId}${attempt ? `/attempts/${attempt}` : ''}`
    : '(run URL 未提供)';
  const runLabel = runId ? `run ${runId}${attempt ? ` attempt ${attempt}` : ''}` : 'run';

  const image = [env.ImageOS, env.ImageVersion].filter(Boolean).join(' / ') || '未提供';
  const arch = env.RUNNER_ARCH ? ` (${env.RUNNER_ARCH})` : '';

  // 6922 = SQLITE_IOERR | (27<<8) = SQLITE_IOERR_VNODE, the decode already on the issue.
  const rc = detail.rc === null ? '未解析'
    : detail.rc === 6922 ? '6922 (`IOERR_VNODE`)' : String(detail.rc);

  const pr = /^(\d+)\/merge$/.exec(env.GITHUB_REF_NAME || '');
  const where = [
    pr ? `PR #${pr[1]}` : (env.GITHUB_REF_NAME ? `ref \`${env.GITHUB_REF_NAME}\`` : null),
    env.GITHUB_JOB ? `job \`${env.GITHUB_JOB}\`` : null,
  ].filter(Boolean).join('，');

  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
  const counts = (s) => (s ? `${plural(s.executed, 'test')} / ${plural(s.failures, 'failure')}` : '未解析');

  return [
    `### #${ISSUE_NUMBER} flake 自动重试（job 内，自动记账）`,
    '',
    '| 日期 | 镜像 | rc | 备注 |',
    '| --- | --- | --- | --- |',
    `| ${date} | ${image}${arch} | ${rc} | **job 内自动重试通过**。[${runLabel}](${runUrl})` +
      `${where ? `，${where}` : ''}。首跑 ${counts(firstSummary)}；重试只跑 ` +
      `\`${FLAKY_TEST}\`（\`--filter\`），${counts(retrySummary)} |`,
    '',
    '首跑失败原文：',
    '',
    '```',
    detail.message ?? '(未解析到失败原文)',
    '```',
    '',
    '本条台账由 `scripts/swift-test-with-retry.mjs` 自动生成。记账是放行的前提：job summary、' +
      'issue 评论、`::warning` 三个通道任一失败，该 job 一律红——「不留痕的自动重跑一律不允许」' +
      '因此仍然成立，这里的重跑是留痕的。',
  ].join('\n');
}

/// Write the ledger entry to all three channels. Any failure throws, and the caller
/// turns that into a red job: an auto-rerun nobody can find afterwards is precisely
/// what issue #400 forbids.
///
/// Order: local first, then the issue, and the log annotation last. Local-before-public
/// means a broken step summary cannot leave a stray comment on a public issue claiming a
/// retry the job then failed to stand behind. Annotation-last means the annotation — the
/// one channel that asserts "and it has been recorded" — is only emitted once that is
/// true, rather than being a promise the next line might break.
export async function record({ env = {}, detail, firstSummary, retrySummary, date, io }) {
  const body = ledgerComment({ env, detail, firstSummary, retrySummary, date });

  const summaryPath = env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) {
    throw new Error('GITHUB_STEP_SUMMARY is not set, so the retry cannot be recorded in the job summary');
  }
  await io.appendFile(summaryPath, `\n${body}\n`);

  const token = env.GITHUB_TOKEN;
  if (!token) {
    throw new Error(
      `GITHUB_TOKEN is not set, so the retry cannot be recorded on issue #${ISSUE_NUMBER}. ` +
      'The job needs `permissions: issues: write`; a fork pull request gets a read-only token ' +
      'regardless and lands here too.');
  }
  const repo = env.GITHUB_REPOSITORY;
  if (!repo) throw new Error('GITHUB_REPOSITORY is not set, so the issue to record against is unknown');

  const api = env.GITHUB_API_URL || 'https://api.github.com';
  const response = await io.fetch(`${api}/repos/${repo}/issues/${ISSUE_NUMBER}/comments`, {
    method: 'POST',
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'x-github-api-version': '2022-11-28',
    },
    body: JSON.stringify({ body }),
  });
  if (response.status !== 201) {
    const text = typeof response.text === 'function' ? await response.text() : '';
    throw new Error(`posting the ledger comment to issue #${ISSUE_NUMBER} returned HTTP ` +
                    `${response.status}: ${text}`);
  }

  io.warn(`::warning::${FLAKY_TEST} failed and passed on a job-internal retry ` +
          `(issue #${ISSUE_NUMBER}). The recurrence has been appended to that issue's ledger.`);
}

// --- orchestration ----------------------------------------------------------

/// Returns the exit code the job should take. Dependencies are injected so the whole
/// decision tree — including "recording failed, so the job fails" — is exercised by
/// scripts/test-swift-test-with-retry.mjs without a compiler or a network.
export async function orchestrate({ runTests, record: recordFn, env = {}, log, date }) {
  const first = await runTests({ filter: null });
  if (first.exitCode === 0) return 0;

  const parsed = parseSwiftTestOutput(first.output);
  const decision = decideRetry(parsed, first.exitCode);
  if (!decision.retry) {
    log(`swift-test-with-retry: not retrying — ${decision.reason}`);
    return first.exitCode || 1;
  }

  // Off CI there is no step summary, no token and no run URL, so a retry could not be
  // recorded; and an unrecorded auto-rerun is the one thing #400 rules out.
  if (env.GITHUB_ACTIONS !== 'true') {
    log(`swift-test-with-retry: ${decision.reason}, but the automatic retry only runs on CI, ` +
        'where it can be recorded. Re-run locally by hand and add a ledger row to ' +
        `issue #${ISSUE_NUMBER}.`);
    return first.exitCode || 1;
  }

  log(`swift-test-with-retry: ${decision.reason} — retrying that test once.`);
  const second = await runTests({ filter: FLAKY_FILTER });
  const retryParsed = parseSwiftTestOutput(second.output);
  const verdict = verifyRetry(retryParsed, second.exitCode);
  if (!verdict.ok) {
    log(`swift-test-with-retry: the retry did not clear it — ${verdict.reason}`);
    return second.exitCode || 1;
  }

  try {
    await recordFn({
      env,
      detail: failureDetail(parsed),
      firstSummary: rootSummary(parsed),
      retrySummary: rootSummary(retryParsed),
      date,
    });
  } catch (error) {
    log(`::error::${FLAKY_TEST} passed on the retry but the recurrence could not be recorded, ` +
        `so this job fails: ${error.message}`);
    return 1;
  }
  return 0;
}

// --- CLI --------------------------------------------------------------------

function swiftTest({ filter }) {
  const args = ['test', '--package-path', PACKAGE_PATH, '--scratch-path', SCRATCH_PATH];
  if (filter) args.push('--filter', filter);
  return new Promise((resolve) => {
    const child = spawn('swift', args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    // XCTest writes to stdout; SwiftPM's build progress to stderr (measured). Both are
    // streamed through so the CI log is unchanged, and both are kept for parsing.
    child.stdout.on('data', (chunk) => { output += chunk; process.stdout.write(chunk); });
    child.stderr.on('data', (chunk) => { output += chunk; process.stderr.write(chunk); });
    child.on('error', (error) => {
      resolve({ exitCode: 1, output: `${output}\nswift-test-with-retry: could not run swift (${error.message})\n` });
    });
    child.on('close', (code, signal) => resolve({ exitCode: signal ? 1 : (code ?? 1), output }));
  });
}

const isMain = process.argv[1] &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));

if (isMain) {
  const code = await orchestrate({
    runTests: swiftTest,
    // `::warning::` is a workflow command, so it has to go to stdout to be picked up.
    record: (args) => record({ ...args, io: { warn: (m) => console.log(m), appendFile, fetch } }),
    env: process.env,
    log: (message) => console.log(message),
    date: new Date().toISOString().slice(0, 10),
  }).catch((error) => {
    console.error(`::error::swift-test-with-retry failed: ${error.stack ?? error.message}`);
    return 1;
  });
  process.exit(code);
}
