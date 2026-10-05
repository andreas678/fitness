// Test für die Zeitraum-Funktionen (presetRange, clampRange, prevRange, matchPreset) aus scripts/dashboard_template.html.
// Aufruf (aus dem Projektordner): node tests/js/test_date_range.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../../scripts/dashboard_template.html", import.meta.url), "utf8");
const m = html.match(/\/\/ <dateRange>([\s\S]*?)\/\/ <\/dateRange>/);
assert.ok(m, "Block // <dateRange> ... // </dateRange> nicht im Template gefunden");
const DAY = 86400000;
const { presetRange, clampRange, prevRange, matchPreset } =
  new Function("DAY", m[1] + "\nreturn { presetRange, clampRange, prevRange, matchPreset };")(DAY);

const d = (y, mo, da) => Date.UTC(y, mo - 1, da);
const MIN = d(2026, 4, 7), MAX = d(2026, 10, 5);          // 182 Tage Daten

// Voreinstellungen: letzte n Tage einschließlich des letzten Datentags; 0 = alles
assert.deepEqual(presetRange(30, MIN, MAX), { from: MAX - 29 * DAY, to: MAX });
assert.deepEqual(presetRange(0, MIN, MAX), { from: MIN, to: MAX });
assert.deepEqual(presetRange(999, MIN, MAX), { from: MIN, to: MAX });   // länger als die Daten: auf den Beginn begrenzt

// Auswahl: vertauschte Werte werden getauscht, außerhalb der Daten wird begrenzt
assert.deepEqual(clampRange(d(2026, 8, 1), d(2026, 7, 1), MIN, MAX), { from: d(2026, 7, 1), to: d(2026, 8, 1) });
assert.deepEqual(clampRange(d(2025, 1, 1), d(2027, 1, 1), MIN, MAX), { from: MIN, to: MAX });
assert.deepEqual(clampRange(d(2026, 7, 1), d(2026, 7, 1), MIN, MAX), { from: d(2026, 7, 1), to: d(2026, 7, 1) });   // ein Tag erlaubt
// ein Wert komplett außerhalb: auf den Rand begrenzt, Anfang bleibt <= Ende
{ const r = clampRange(d(2027, 1, 1), d(2027, 2, 1), MIN, MAX); assert.ok(r.from <= r.to && r.from >= MIN && r.to <= MAX); }
// Zeitstempel mit Uhrzeit werden auf ganze Tage gerundet
assert.deepEqual(clampRange(d(2026, 7, 1) + 3600000, d(2026, 8, 1) - 3600000, MIN, MAX), { from: d(2026, 7, 1), to: d(2026, 8, 1) });

// Vorzeitraum: gleich lang, direkt davor; nur wenn vollständig von Daten gedeckt
assert.deepEqual(prevRange(d(2026, 8, 1), d(2026, 8, 30), MIN), [d(2026, 7, 2), d(2026, 7, 31)]);   // 30 Tage
assert.equal(prevRange(MIN, MAX, MIN), null);                                                      // "Alles": kein Vorzeitraum
assert.equal(prevRange(d(2026, 4, 20), d(2026, 5, 20), MIN), null);                                // Vorzeitraum reicht vor den Datenbeginn

// Voreinstellung erkennen (für die Auswahlliste), sonst eigener Zeitraum
assert.equal(matchPreset(MAX - 89 * DAY, MAX, MIN, MAX), 90);
assert.equal(matchPreset(MIN, MAX, MIN, MAX), 0);
assert.equal(matchPreset(d(2026, 7, 1), d(2026, 8, 1), MIN, MAX), null);
assert.equal(matchPreset(MAX - 29 * DAY, MAX - DAY, MIN, MAX), null);                              // Ende nicht der letzte Datentag

console.log("dateRange: alle Tests bestanden");
