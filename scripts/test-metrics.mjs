// Offline unit test for the month-over-month / year-over-year / price-index computation (PR-A).
// Pure function, no DB / no network. Locks: normal calc, missing prior month, missing prior year,
// base period 0, and the null-on-no-base-period contract (never 0.0%).
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { computeMonthlyComparisons, pct } = require('../electron/handlers/_metrics.js');

const failures = [];
function check(name, cond, detail) {
  if (cond) console.log(`  ✓ ${name}`);
  else { console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); failures.push(name); }
}
const approx = (a, b) => a != null && b != null && Math.abs(a - b) < 0.05;

console.log('\n=== Metrics comparisons (offline) ===\n');

console.log('pct:');
check('pct base 0 → null', pct(100, 0) === null);
check('pct base null → null', pct(100, null) === null);
check('pct normal +20', pct(120, 100) === 20);
check('pct negative -25', pct(90, 120) === -25);

console.log('mom / yoy:');
{
  const monthly = [{ revenue: 100, salesTons: 0 }, { revenue: 120, salesTons: 0 }, { revenue: 90, salesTons: 0 }];
  const out = computeMonthlyComparisons(monthly, [80, 100, 100]);
  check('mom[0] null (no prior month)', out[0].mom === null);
  check('mom[1] +20 (120 vs 100)', out[1].mom === 20);
  check('mom[2] -25 (90 vs 120)', out[2].mom === -25);
  check('yoy[0] +25 (100 vs 80)', out[0].yoy === 25);
  check('yoy[1] +20 (120 vs 100)', out[1].yoy === 20);
  check('yoy[2] -10 (90 vs 100)', out[2].yoy === -10);
}
{
  const out = computeMonthlyComparisons([{ revenue: 100, salesTons: 0 }, { revenue: 120, salesTons: 0 }], []);
  check('yoy all null (no prior year)', out.every(o => o.yoy === null));
}
{
  const out = computeMonthlyComparisons([{ revenue: 0, salesTons: 0 }, { revenue: 100, salesTons: 0 }], [0, 50]);
  check('mom base 0 → null (NOT 0.0%)', out[1].mom === null);
  check('yoy base 0 → null', out[0].yoy === null);
  check('yoy normal after 0 base (+100)', out[1].yoy === 100);
}

console.log('deflator (price index):');
{
  // unit revenue 100/10=10 and 80/5=16 → avg 13 → 76.9 / null / 123.1
  const out = computeMonthlyComparisons([
    { revenue: 100, salesTons: 10 }, { revenue: 50, salesTons: 0 }, { revenue: 80, salesTons: 5 },
  ], []);
  check('deflator[0] ≈ 76.9', approx(out[0].deflator, 76.9), String(out[0].deflator));
  check('deflator[1] null (salesTons 0)', out[1].deflator === null);
  check('deflator[2] ≈ 123.1', approx(out[2].deflator, 123.1), String(out[2].deflator));
}
{
  const out = computeMonthlyComparisons([{ revenue: 100, salesTons: 0 }, { revenue: 50, salesTons: 0 }], []);
  check('deflator all null (no sales volume)', out.every(o => o.deflator === null));
}

console.log(`\n${failures.length === 0 ? '✓ all passed' : '✗ ' + failures.length + ' failed'}\n`);
process.exit(failures.length === 0 ? 0 : 1);
