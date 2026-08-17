#!/usr/bin/env node
// Pins the semantics of the #400 flake retry (scripts/swift-test-with-retry.mjs).
//
// Run: node scripts/test-swift-test-with-retry.mjs
//
// The retry itself cannot be demonstrated on demand — the flake fires when it feels
// like it, and manufacturing a failure to show the mechanism working would be theatre,
// not evidence. So the whole decision tree is driven here through injected fakes
// instead: no compiler, no network, no runner. The `swift test` text these cases parse
// is quoted from real runs (the failing one from job 95182149772 of run 31954181406,
// the rest measured locally), so the parser is pinned against output that actually
// occurred rather than output imagined for it.
//
// The property that matters most is at the bottom: `orchestrate` returns 0 only along
// a path that has already awaited `record`, and any recording failure turns a passing
// retry into a red job. That is what makes "an auto-rerun that leaves no trace is
// never allowed" a mechanism rather than a promise.
import {
  parseSwiftTestOutput, rootSummary, failureDetail, decideRetry, verifyRetry,
  ledgerComment, record, orchestrate,
  FLAKY_TEST, FLAKY_FILTER, FLAKY_MODULE, FLAKY_SUITE, FLAKY_METHOD, ISSUE_NUMBER,
  PACKAGE_PATH, SCRATCH_PATH,
} from './swift-test-with-retry.mjs';

let failures = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`✗ ${name}\n    expected ${e}\n    actual   ${a}`);
}
function checkTrue(name, actual) { check(name, actual, true); }

// --- fixtures ---------------------------------------------------------------
// Quoted shapes. `caseLine`/`errorLine` reproduce XCTest's exact spelling, including
// the singular/plural swings ("1 test" vs "1288 tests", "1 failure" vs "0 failures")
// that a count-by-wording parser would trip over.

const caseLine = (suite, method, verdict) =>
  `Test Case '-[${FLAKY_MODULE}.${suite} ${method}]' ${verdict} (0.310 seconds).`;

const errorLine = (suite, method, message) =>
  `/Users/runner/work/ai-dashboard/ai-dashboard/native/SoloLedger/Tests/SoloLedgerCoreTests/` +
  `${suite}.swift:258: error: -[${FLAKY_MODULE}.${suite} ${method}] : ${message}`;

const VNODE = 'failed - expected identity(moved), got hasMovedFailed(fileControlRC: 6922, systemErrno: 0)';

const summary = (executed, fails, unexpected = 0) =>
  `\t Executed ${executed} test${executed === 1 ? '' : 's'}, with ${fails} ` +
  `failure${fails === 1 ? '' : 's'} (${unexpected} unexpected) in 55.824 (56.100) seconds`;

/// A whole-suite run. `bad` is the list of [suite, method] pairs that failed.
const fullRun = (bad, { rootPrinted = true, unexpected = 0 } = {}) => {
  const lines = [
    "Test Suite 'All tests' started at 2026-08-16 15:00:13.284.",
    "Test Suite 'SoloLedgerPackageTests.xctest' started at 2026-08-16 15:00:13.296.",
    caseLine('LedgerStoreTests', 'testOpensAnExistingLedger', 'passed'),
    caseLine(FLAKY_SUITE, 'testHasMovedPrimitive', 'passed'),
  ];
  for (const [suite, method] of bad) {
    lines.push(errorLine(suite, method, VNODE), caseLine(suite, method, 'failed'));
  }
  const verdict = bad.length ? 'failed' : 'passed';
  lines.push(`Test Suite 'SoloLedgerPackageTests.xctest' ${verdict} at 2026-08-16 15:01:09.384.`,
             summary(1288, bad.length, unexpected));
  if (rootPrinted) {
    lines.push(`Test Suite 'All tests' ${verdict} at 2026-08-16 15:01:09.384.`,
               summary(1288, bad.length, unexpected));
  }
  lines.push('◇ Test run started.', '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.');
  return lines.join('\n');
};

/// A `--filter`ed run. `hit === false` reproduces the measured shape of a filter that
/// matches nothing: exit 0, `Executed 0 tests`, and a cheerful "passed". `also` adds
/// further tests the pattern swept in, which is what an unanchored filter would do.
const filteredRun = ({ hit = true, verdict = 'passed', also = [] } = {}) => {
  const lines = ["Test Suite 'Selected tests' started at 2026-08-16 18:17:14.933.",
                 "Test Suite 'SoloLedgerPackageTests.xctest' started at 2026-08-16 18:17:14.933."];
  if (!hit) lines.splice(0, 0, 'warning: No matching test cases were run');
  const ran = [];
  if (hit) ran.push([FLAKY_SUITE, FLAKY_METHOD]);
  ran.push(...also);
  if (ran.length) {
    lines.push(`Test Suite '${FLAKY_SUITE}' started at 2026-08-16 18:17:14.933.`);
    for (const [suite, method] of ran) lines.push(caseLine(suite, method, verdict));
    lines.push(`Test Suite '${FLAKY_SUITE}' ${verdict} at 2026-08-16 18:17:14.947.`,
               summary(ran.length, verdict === 'failed' ? ran.length : 0));
  }
  const fails = verdict === 'failed' ? ran.length : 0;
  lines.push(`Test Suite 'SoloLedgerPackageTests.xctest' ${verdict} at 2026-08-16 18:17:14.947.`,
             summary(ran.length, fails),
             `Test Suite 'Selected tests' ${verdict} at 2026-08-16 18:17:14.947.`,
             summary(ran.length, fails));
  return lines.join('\n');
};

const THE_FLAKE = [[FLAKY_SUITE, FLAKY_METHOD]];

// --- the constants the rest of the repository is pinned against -------------

check('the retried test is named in three consistent spellings',
  [FLAKY_TEST, FLAKY_FILTER],
  [`${FLAKY_SUITE}.${FLAKY_METHOD}`, `${FLAKY_MODULE}\\.${FLAKY_SUITE}/${FLAKY_METHOD}$`]);
check('the ledger is issue #400', ISSUE_NUMBER, 400);
check('the package and scratch path are the ones ci.yml used', [PACKAGE_PATH, SCRATCH_PATH],
  ['native/SoloLedger', '.swift-gate-build']);

// --- parsing ----------------------------------------------------------------

const parsedFlake = parseSwiftTestOutput(fullRun(THE_FLAKE));
check('a failing run yields exactly the failed test', parsedFlake.failed, [FLAKY_TEST]);
check('…and the passing ones are kept apart from it',
  parsedFlake.passed,
  ['LedgerStoreTests.testOpensAnExistingLedger', `${FLAKY_SUITE}.testHasMovedPrimitive`]);
check('the root summary is the "All tests" one', rootSummary(parsedFlake),
  { suite: 'All tests', executed: 1288, failures: 1, unexpected: 0 });
check('the rc is read out of the failure text', failureDetail(parsedFlake).rc, 6922);
check('…along with the message itself, for the ledger',
  failureDetail(parsedFlake).message, VNODE);

check('a filtered run reports under "Selected tests"', rootSummary(parseSwiftTestOutput(filteredRun())),
  { suite: 'Selected tests', executed: 1, failures: 0, unexpected: 0 });
check('a green whole run has no failures', parseSwiftTestOutput(fullRun([])).failed, []);

// The singular/plural swing is XCTest's, not ours: "1 test, with 1 failure" and
// "1288 tests, with 0 failures" both have to read as numbers.
check('counts are read as numbers regardless of pluralisation',
  parseSwiftTestOutput([summary(1, 1), "Test Suite 'All tests' failed at x.",
                        summary(1288, 0)].join('\n')).summaries.map((s) => [s.executed, s.failures]),
  [[1, 1], [1288, 0]]);

// A summary belongs to the suite line above it; getting that wrong would let a nested
// suite's "1 failure" pass for the whole run's.
check('a nested suite summary is not mistaken for the root one',
  rootSummary(parseSwiftTestOutput([
    "Test Suite 'HardenedActiveOpenTests' failed at x.", summary(20, 1),
    "Test Suite 'All tests' failed at x.", summary(1288, 1),
  ].join('\n'))),
  { suite: 'All tests', executed: 1288, failures: 1, unexpected: 0 });

check('prose that merely quotes a test-case line is not a test case',
  parseSwiftTestOutput(`# ${caseLine(FLAKY_SUITE, FLAKY_METHOD, 'failed')}`).failed, []);
check('an empty log yields nothing rather than silent agreement',
  [parseSwiftTestOutput('').failed, rootSummary(parseSwiftTestOutput(''))], [[], null]);

// --- the decision to retry --------------------------------------------------

checkTrue('the tracked flake alone, on a red run → retry',
  decideRetry(parsedFlake, 1).retry);

check('a green run is never retried', decideRetry(parseSwiftTestOutput(fullRun([])), 0).retry, false);

// The two shapes the task book names explicitly.
check('two failures → no retry, even when one of them is the flake',
  decideRetry(parseSwiftTestOutput(
    fullRun([[FLAKY_SUITE, FLAKY_METHOD], ['LedgerStoreTests', 'testSomethingElse']])), 1).retry,
  false);
check('a different single failure → no retry',
  decideRetry(parseSwiftTestOutput(fullRun([['LedgerStoreTests', 'testSomethingElse']])), 1).retry,
  false);

// A name that merely starts the same must not be swept in with it — the filter is
// anchored, and so is the comparison.
check('a longer name with the same prefix is a different test',
  decideRetry(parseSwiftTestOutput(fullRun([[FLAKY_SUITE, `${FLAKY_METHOD}Twice`]])), 1).retry,
  false);
check('the same method on another suite is a different test',
  decideRetry(parseSwiftTestOutput(fullRun([['HardenedFreshOpenTests', FLAKY_METHOD]])), 1).retry,
  false);

// Fail-closed shapes: the log has to agree with itself before anything is re-run.
check('a red run with no root summary → no retry (a crash is not this flake)',
  decideRetry(parseSwiftTestOutput(fullRun(THE_FLAKE, { rootPrinted: false })), 1).retry, false);
check('an "unexpected" failure → no retry',
  decideRetry(parseSwiftTestOutput(fullRun(THE_FLAKE, { unexpected: 1 })), 1).retry, false);
check('a red run whose summary claims no failures → no retry',
  decideRetry(parseSwiftTestOutput([
    caseLine(FLAKY_SUITE, FLAKY_METHOD, 'failed'),
    "Test Suite 'All tests' failed at x.", summary(1288, 0),
  ].join('\n')), 1).retry, false);
check('a red run with no parsed failure at all → no retry',
  decideRetry(parseSwiftTestOutput('swift: fatal error\n'), 1).retry, false);

// The two checks below each have their own killing case on purpose. Cases that any
// two checks would both catch prove neither of them; a mutation that deletes one and
// survives is either a test gap or a redundant branch, and both want fixing.
check('a run that EXITED 0 is never retried, whatever its log says',
  decideRetry(parsedFlake, 0).retry, false);
check('names and summary disagreeing → no retry, even when the count looks right',
  decideRetry(parseSwiftTestOutput([
    caseLine(FLAKY_SUITE, FLAKY_METHOD, 'failed'),
    caseLine('LedgerStoreTests', 'testX', 'failed'),
    "Test Suite 'All tests' failed at x.", summary(1288, 1),
  ].join('\n')), 1).retry, false);

// --- verifying the retry ----------------------------------------------------

checkTrue('a retry that runs the test and passes is accepted',
  verifyRetry(parseSwiftTestOutput(filteredRun()), 0).ok);

// The measured trap: `--filter` with a pattern that matches nothing exits 0 and says
// "Executed 0 tests". Without this, one typo in the filter makes the gate vacuous.
check('a filter that matched nothing is NOT a pass, despite exit 0',
  verifyRetry(parseSwiftTestOutput(filteredRun({ hit: false })), 0).ok, false);
check('…and the reason says so',
  /matches nothing/.test(verifyRetry(parseSwiftTestOutput(filteredRun({ hit: false })), 0).reason), true);

check('a retry that fails is not a pass',
  verifyRetry(parseSwiftTestOutput(filteredRun({ verdict: 'failed' })), 1).ok, false);
check('a retry exiting 0 with no summary at all is not a pass',
  verifyRetry(parseSwiftTestOutput(''), 0).ok, false);
check('a retry that ran the whole suite is not a single-test retry',
  verifyRetry(parseSwiftTestOutput(fullRun([])), 0).ok, false);

// One killing case each, again. "executed exactly 1" and "this test passed" overlap on
// the filter-miss shape above, so each also gets a case only IT can catch: a pattern
// that swept in a second test (count wrong, name right), and one that hit a different
// test entirely (count right, name wrong).
check('a retry that swept in a second test is not a single-test retry',
  verifyRetry(parseSwiftTestOutput(
    filteredRun({ also: [[FLAKY_SUITE, `${FLAKY_METHOD}Twice`]] })), 0).ok, false);
check('a retry that ran one test, but the wrong one, is not a pass',
  verifyRetry(parseSwiftTestOutput(
    filteredRun({ hit: false, also: [[FLAKY_SUITE, 'testHasMovedPrimitive']] })), 0).ok, false);

// --- the ledger entry -------------------------------------------------------

const ENV = {
  GITHUB_ACTIONS: 'true',
  GITHUB_SERVER_URL: 'https://github.com',
  GITHUB_REPOSITORY: 'alotie418/ai-dashboard',
  GITHUB_RUN_ID: '31954181406',
  GITHUB_RUN_ATTEMPT: '1',
  GITHUB_REF_NAME: '484/merge',
  GITHUB_JOB: 'checks',
  GITHUB_STEP_SUMMARY: '/tmp/step-summary',
  GITHUB_TOKEN: 'x-token',
  ImageOS: 'macos26',
  ImageVersion: '20260728.0273.1',
  RUNNER_ARCH: 'ARM64',
};
const COMMENT = ledgerComment({
  env: ENV,
  detail: failureDetail(parsedFlake),
  firstSummary: rootSummary(parsedFlake),
  retrySummary: rootSummary(parseSwiftTestOutput(filteredRun())),
  date: '2026-08-16',
});

// The five fields the ledger row is required to carry.
for (const [what, needle] of [
  ['the date', '2026-08-16'],
  ['the image and its version', 'macos26 / 20260728.0273.1 (ARM64)'],
  ['the rc, decoded', '6922 (`IOERR_VNODE`)'],
  ['the run URL', 'https://github.com/alotie418/ai-dashboard/actions/runs/31954181406/attempts/1'],
  ['the words that say what happened', '**job 内自动重试通过**'],
]) check(`the ledger entry carries ${what}`, COMMENT.includes(needle), true);

check('…and names the test, the PR and both run counts',
  ['`HardenedActiveOpenTests.testPostOpenUnlinkCaughtByHasMoved`', 'PR #484',
   '1288 tests / 1 failure', '1 test / 0 failures'].every((s) => COMMENT.includes(s)), true);
check('…and quotes the failure text so the rc can be checked by eye',
  COMMENT.includes(VNODE), true);
check('an unparsed rc is admitted, not invented',
  ledgerComment({ env: ENV, detail: { message: null, rc: null }, firstSummary: null,
                  retrySummary: null, date: '2026-08-16' }).includes('| 未解析 |'), true);

// --- recording: three channels, all of them load-bearing --------------------

function fakeIo({ postStatus = 201 } = {}) {
  const calls = { warn: [], appended: [], posted: [] };
  return {
    calls,
    io: {
      warn: (m) => calls.warn.push(m),
      appendFile: async (path, text) => { calls.appended.push([path, text]); },
      fetch: async (url, init) => {
        calls.posted.push([url, JSON.parse(init.body).body, init.headers.authorization]);
        return { status: postStatus, text: async () => 'boom' };
      },
    },
  };
}
const recordArgs = (env, io) => ({
  env,
  detail: failureDetail(parsedFlake),
  firstSummary: rootSummary(parsedFlake),
  retrySummary: rootSummary(parseSwiftTestOutput(filteredRun())),
  date: '2026-08-16',
  io,
});
async function rejects(name, promise, needle) {
  try {
    await promise;
    failures++;
    console.error(`✗ ${name}\n    expected a rejection, got none`);
  } catch (error) {
    check(name, error.message.includes(needle), true);
  }
}

const happy = fakeIo();
await record(recordArgs(ENV, happy.io));
check('recording annotates the log', happy.calls.warn.length, 1);
check('…with a ::warning:: workflow command naming the issue',
  happy.calls.warn[0].startsWith(`::warning::${FLAKY_TEST} failed and passed`) &&
  happy.calls.warn[0].includes(`#${ISSUE_NUMBER}`), true);
check('recording writes the job step summary', happy.calls.appended.length, 1);
check('…to the path the runner named', happy.calls.appended[0][0], '/tmp/step-summary');
check('recording posts a comment on the issue', happy.calls.posted.length, 1);
check('…to issue #400 of this repository', happy.calls.posted[0][0],
  `https://api.github.com/repos/alotie418/ai-dashboard/issues/${ISSUE_NUMBER}/comments`);
check('…bearing the token', happy.calls.posted[0][2], 'Bearer x-token');
check('…and the same text the summary got', happy.calls.posted[0][1], happy.calls.appended[0][1].trim());

await rejects('no token → recording fails (a fork PR, or a job without issues:write)',
  record(recordArgs({ ...ENV, GITHUB_TOKEN: '' }, fakeIo().io)), 'GITHUB_TOKEN is not set');
await rejects('no step summary → recording fails',
  record(recordArgs({ ...ENV, GITHUB_STEP_SUMMARY: '' }, fakeIo().io)), 'GITHUB_STEP_SUMMARY is not set');
await rejects('no repository → recording fails rather than guessing which issue to write to',
  record(recordArgs({ ...ENV, GITHUB_REPOSITORY: '' }, fakeIo().io)), 'GITHUB_REPOSITORY is not set');
const refused = fakeIo({ postStatus: 403 });
await rejects('an API refusal → recording fails',
  record(recordArgs(ENV, refused.io)), 'returned HTTP 403');

// Ordering, proved by what did NOT happen. Local before public: a broken step summary
// must not leave a comment behind claiming a retry the job then refused to stand behind.
const localBroken = fakeIo();
await rejects('a failed local channel stops before the issue is touched',
  record(recordArgs({ ...ENV, GITHUB_STEP_SUMMARY: '' }, localBroken.io)), 'GITHUB_STEP_SUMMARY');
check('…so nothing was posted', localBroken.calls.posted.length, 0);
check('…and nothing was annotated', localBroken.calls.warn.length, 0);

// Annotation last, because it is the one channel that asserts "…and it has been
// recorded". It must not be emitted by a run that then failed to record.
check('a refused post leaves no annotation claiming the ledger was written',
  refused.calls.warn.length, 0);
check('…though the step summary it had already written stands', refused.calls.appended.length, 1);

// --- orchestration: the whole tree, with fakes ------------------------------

function harness({ runs, recordBehaviour = async () => {}, env = ENV }) {
  const seen = { filters: [], recorded: 0, logs: [], recordedBeforeReturn: null };
  // A run the case did not plan for returns a sentinel rather than `undefined`, so an
  // orchestrator that retries once too often fails an assertion about `seen.filters`
  // instead of dying on a TypeError — a crash is red too, but it stops the rest of the
  // case from running and says less about what went wrong.
  const runTests = async ({ filter }) => {
    seen.filters.push(filter);
    return runs[seen.filters.length - 1] ?? { exitCode: 97, output: '' };
  };
  const recordFn = async (args) => { seen.recorded++; return recordBehaviour(args); };
  return {
    seen,
    run: () => orchestrate({ runTests, record: recordFn, env, log: (m) => seen.logs.push(m),
                            date: '2026-08-16' }),
  };
}
const RED_FLAKE = { exitCode: 1, output: fullRun(THE_FLAKE) };
const GREEN_RETRY = { exitCode: 0, output: filteredRun() };

const green = harness({ runs: [{ exitCode: 0, output: fullRun([]) }] });
check('a green suite runs once and records nothing', [await green.run(), green.seen.filters, green.seen.recorded],
  [0, [null], 0]);

const retried = harness({ runs: [RED_FLAKE, GREEN_RETRY] });
check('the flake alone → retried once, recorded, green',
  [await retried.run(), retried.seen.recorded], [0, 1]);
check('…and the retry ran only that test', retried.seen.filters, [null, FLAKY_FILTER]);

const otherFailure = harness({ runs: [{ exitCode: 1, output: fullRun([['LedgerStoreTests', 'testX']]) }] });
check('another failure → one run, no record, red',
  [await otherFailure.run(), otherFailure.seen.filters.length, otherFailure.seen.recorded], [1, 1, 0]);

const twoFailures = harness({
  runs: [{ exitCode: 1, output: fullRun([[FLAKY_SUITE, FLAKY_METHOD], ['LedgerStoreTests', 'testX']]) }],
});
check('two failures → one run, no record, red',
  [await twoFailures.run(), twoFailures.seen.filters.length, twoFailures.seen.recorded], [1, 1, 0]);

const retryStillRed = harness({ runs: [RED_FLAKE, { exitCode: 1, output: filteredRun({ verdict: 'failed' }) }] });
check('the retry fails too → red, and nothing is recorded',
  [await retryStillRed.run(), retryStillRed.seen.recorded], [1, 0]);

// The measured false-green: filter matches nothing, `swift test` exits 0. The job must
// still be red, and — the part that matters — no ledger entry may be written for a
// retry that never ran.
const retryVacuous = harness({ runs: [RED_FLAKE, { exitCode: 0, output: filteredRun({ hit: false }) }] });
check('a retry that ran no test is red and unrecorded',
  [await retryVacuous.run(), retryVacuous.seen.recorded], [1, 0]);

// The load-bearing property. A passing retry that cannot be recorded is a red job:
// 0 is reachable only through a completed `record`.
const unrecordable = harness({
  runs: [RED_FLAKE, GREEN_RETRY],
  recordBehaviour: async () => { throw new Error('no token'); },
});
check('a passing retry that cannot be recorded fails the job',
  [await unrecordable.run(), unrecordable.seen.recorded], [1, 1]);
check('…and says why, as an error annotation',
  unrecordable.seen.logs.some((l) => l.startsWith('::error::') && l.includes('could not be recorded')), true);

// Off CI there is no step summary, no token and no run URL, so there is nowhere to
// record it — and an unrecorded auto-rerun is the one thing #400 rules out.
const local = harness({ runs: [RED_FLAKE], env: { ...ENV, GITHUB_ACTIONS: undefined } });
check('off CI the flake is reported but never retried',
  [await local.run(), local.seen.filters, local.seen.recorded], [1, [null], 0]);
check('…and the message points at the manual ledger',
  local.seen.logs.some((l) => l.includes(`issue #${ISSUE_NUMBER}`)), true);

if (failures) {
  console.error(`\n${failures} flake-retry semantic(s) broken`);
  process.exit(1);
}
console.log(`✓ #${ISSUE_NUMBER} flake retry: all semantics hold`);
