// Test für rollMean() (rollierendes Mittel über Kalendertage) aus scripts/dashboard_template.html gegen die von Hand
// gerechneten Fälle in tests/fixtures/rolling.json. Dieselben Fälle prüft roll_apply() in R (tests/testthat/test-helpers.R).
// Aufruf (aus dem Projektordner): node tests/js/test_roll_mean.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../../scripts/dashboard_template.html", import.meta.url), "utf8");
const m = html.match(/\/\/ <rollMean>([\s\S]*?)\/\/ <\/rollMean>/);
assert.ok(m, "Block // <rollMean> ... // </rollMean> nicht im Template gefunden");
const DAY = 86400000;
const mean = a => { const v = a.filter(x => x != null && !Number.isNaN(x)); return v.length ? v.reduce((s, x) => s + x, 0) / v.length : null; };   // wie im Template
const { rollMean } = new Function("DAY", "mean", m[1] + "\nreturn { rollMean };")(DAY, mean);

const fixture = JSON.parse(readFileSync(new URL("../fixtures/rolling.json", import.meta.url), "utf8"));
let n = 0, skipped = 0;
for (const c of fixture.cases) {
  if (c.lag_by !== 0) { skipped++; continue; }                 // das JavaScript kennt nur das Fenster bis zum Tag selbst
  const times = c.dates.map(d => Date.parse(d + "T00:00:00Z"));
  const got = rollMean(c.values, times, c.k, c.min_n);
  assert.equal(got.length, c.expected.length, c.name);
  got.forEach((g, i) => {
    const e = c.expected[i];
    if (e === null) assert.equal(g, null, `${c.name}: Position ${i + 1} sollte fehlen, ist ${g}`);
    else { assert.notEqual(g, null, `${c.name}: Position ${i + 1} fehlt, erwartet ${e}`); assert.ok(Math.abs(g - e) < 1e-9, `${c.name}: Position ${i + 1}: ${g} statt ${e}`); }
  });
  n++;
}
assert.ok(n >= 4, "zu wenige Fälle geprüft");
console.log(`rollMean: ${n} Fälle bestanden (${skipped} mit lag_by übersprungen)`);
