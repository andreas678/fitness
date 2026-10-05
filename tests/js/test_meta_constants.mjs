// Wächter: Das Dashboard-Template enthält keine eigenen Literale für Konstanten, die aus R über META kommen
// (helpers.R: STEP_GOAL, GROUP_COLORS, ACWR_*; weather.R: HEAT_C). Ändert jemand den Wert nur im Template,
// wären R und Dashboard stillschweigend uneinig.
// Aufruf (aus dem Projektordner): node tests/js/test_meta_constants.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../../scripts/dashboard_template.html", import.meta.url), "utf8");
const script = html.slice(html.indexOf("<script>"));
// Kommentare weg, damit Erklärungen nicht als Literale zählen
const code = script.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");

const mustNotContain = [
  [/\b10000\b/,                   "Schrittziel (META.step_goal)"],
  [/\b0[.,]8\b/,                  "ACWR-Untergrenze (META.acwr.low)"],
  [/\b1[.,]3\b/,                  "ACWR-Obergrenze (META.acwr.high)"],
  [/ACWR\.very_high\s*=\s*1[.,]5/, "ACWR 'hoch' (META.acwr.very_high)"],
  [/\bHEAT_C\s*=\s*\d/,           "Hitzetag-Schwelle (META.heat_c)"],
  [/const\s+GROUP_COLORS\s*=\s*\{/, "Gruppenfarben als Objekt-Literal (META.group_colors)"],
  [/\ba\s*(<|<=|>)\s*1[.,]5\b/,   "ACWR 'hoch' als Vergleich mit 1,5 (META.acwr.very_high)"],
];
for (const [re, what] of mustNotContain)
  assert.ok(!re.test(code), `Template enthält ein Literal für ${what}`);

// Positiv: die Konstanten werden aus META gelesen
const mustContain = [
  /GROUP_COLORS\s*=\s*META\.group_colors/, /STEP_GOAL\s*=\s*META\.step_goal/,
  /HEAT_C\s*=\s*META\.heat_c/, /ACWR\s*=\s*META\.acwr/,
];
for (const re of mustContain) assert.ok(re.test(code), `Template liest nicht aus META: ${re}`);

console.log("OK: Template nutzt für STEP_GOAL, GROUP_COLORS, ACWR und HEAT_C nur META");
