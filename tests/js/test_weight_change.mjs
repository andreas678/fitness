// Test für weightChange() aus scripts/dashboard_template.html.
// Aufruf (aus dem Projektordner): node tests/js/test_weight_change.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../../scripts/dashboard_template.html", import.meta.url), "utf8");
const m = html.match(/\/\/ <weightChange>([\s\S]*?)\/\/ <\/weightChange>/);
assert.ok(m, "Block // <weightChange> ... // </weightChange> nicht im Template gefunden");
const weightChange = new Function(m[1] + "\nreturn weightChange;")();

const DAY = 86400000, T0 = Date.UTC(2026, 0, 1);
const pts = (days, kg) => days.map((d, i) => ({ t: T0 + d * DAY, kg: kg[i] }));
const near = (a, b, tol = 1e-4) => assert.ok(Math.abs(a - b) < tol, `${a} != ${b}`);

// Referenz aus R: lm(kg ~ day), 95-%-Intervall mit t-Quantil (df = 5)
{
  const r = weightChange(pts([0, 10, 20, 35, 50, 70, 90], [91.9, 91.5, 90.9, 91.0, 90.2, 89.7, 89.3]));
  assert.equal(r.n, 7);
  near(r.change, -2.561846); near(r.lo, -3.130761); near(r.hi, -1.992932);
}
// zu wenige Wiegungen: kein Trend
assert.equal(weightChange(pts([0, 10, 20, 30, 40], [90, 90, 90, 90, 90])), null);
assert.equal(weightChange([]), null);
// ohne Streuung der Zeitpunkte (alle am selben Tag): kein Trend
assert.equal(weightChange(pts([5, 5, 5, 5, 5, 5], [90, 91, 90, 91, 90, 91])), null);
// exakte Gerade: Änderung = Steigung * Zeitspanne, Intervall ohne Breite
{
  const r = weightChange(pts([0, 10, 20, 30, 40, 50], [90, 89, 88, 87, 86, 85]));
  near(r.change, -5); near(r.lo, -5); near(r.hi, -5);
}
// unsortierte Eingabe liefert dasselbe
{
  const a = weightChange(pts([0, 10, 20, 35, 50, 70, 90], [91.9, 91.5, 90.9, 91.0, 90.2, 89.7, 89.3]));
  const b = weightChange(pts([90, 0, 50, 20, 70, 10, 35], [89.3, 91.9, 90.2, 90.9, 89.7, 91.5, 91.0]));
  near(a.change, b.change);
}
// Streuung ohne Trend: Intervall schließt die Null ein
{
  const r = weightChange(pts([0, 12, 25, 40, 55, 70, 85, 100], [90.2, 91.1, 89.8, 90.9, 90.3, 91.0, 89.9, 90.6]));
  assert.ok(r.lo < 0 && r.hi > 0, `erwartet Intervall um 0, war [${r.lo}, ${r.hi}]`);
}
console.log("weightChange: alle Tests bestanden");
