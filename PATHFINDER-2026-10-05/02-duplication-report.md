# Duplikat-Bericht (Pathfinder Phase 2)

Grundlage: die sechs Flowchart-Berichte in `01-flowcharts/`. Jede Behauptung nennt mindestens zwei Fundstellen. Ich habe diese Stellen stichprobenartig per `grep` gegen den Quelltext geprüft: `RIDE_*`, `roll_mean`/`roll_apply`/`roll`, `GROUP_COLORS`, `STEP_GOAL`, ACWR-Band, `fmtP`, `HEAT_C`, `NeweyWest`, doppeltes Einlesen der Aktivitäten-CSV. Alle Stichproben stimmen mit dem Bericht überein.

Hinweis zum Vorgehen: Der Skill sieht zwei Duplikat-Subagenten vor. Die Feature-Agenten haben ihre Duplikate schon mit Belegen geliefert, deshalb habe ich sie selbst zusammengeführt und nur noch geprüft.

Legende: **Zufällig** = unbeabsichtigte Abweichung, Vereinheitlichung lohnt. **Legitim** = echte Spezialisierung, bleibt.

## A. Konstanten und Schwellen (Feature 1, 2, 3, 5, 6)

| # | Konzept | Fundstellen | Ursache | Urteil |
|---|---|---|---|---|
| A1 | `RIDE_GAP_MIN = 30`, `RIDE_MIN_MIN = 3` | `garmin_fitness.R:61-62`, `build_dashboard.R:25-26` (Kommentar „wie in garmin_fitness.R“), Standardwerte `helpers.R:25`, Literale in `tests/testthat/test-helpers.R:13,24,31,38,43,50` und `tests/audit/*.R` | Beim Aufspalten in zwei Skripte kopiert | **Zufällig.** Drei Quellcode-Kopien, dazu 12 Literale in Tests und Audits |
| A2 | `STEP_GOAL = 10000` | `garmin_fitness.R:60`, `dashboard_template.html:173` | R-Plots und JS getrennt gewachsen | **Zufällig** (JS könnte `META` lesen) |
| A3 | `GROUP_COLORS` (6 Gruppen, gleiche Hex-Werte) und Gruppennamen | `garmin_fitness.R:78-85`, `dashboard_template.html:170`; Namen in `helpers.R:7-17` und im JS `:274`, `:275`, `:663`, `:664` | wie A2 | **Zufällig**, verschwindet teils mit Feature 6 (siehe C) |
| A4 | ACWR-Band 0,8 / 1,3 | Template `:311-312`, `:393-394`, `:510`, Text `:134`; in R keine Konstante | Nur im Frontend entstanden | **Zufällig.** Die Notion-Seite nennt den Bereich als „groben Richtwert“. Er sollte an einer Stelle stehen. |
| A5 | Hitzetag-Schwelle 30 °C | `dashboard_template.html:537` (`HEAT_C`), Notion „Hitzetage ab 30 °C“; in `weather.R` keine Konstante | Nur im JS | **Zufällig** (eine Quelle in R genügt) |
| A6 | `MIN_RHR`, `MIN_SLEEP_H` | `helpers.R:56-57`; über `META` im JS (`build_dashboard.R:145`, Template `:174`) | — | **Legitim.** Das ist die vorbildliche Lösung (eine Quelle, Export per `META`). Kleiner Rest: `META.min_rhr` und `META.ride_min_min` werden vom JS nie gelesen. |
| A7 | `MIN_STEPS = 500` | `helpers.R:58`, `load_recovery.R:239`; JS nutzt das `partial`-Flag | — | **Legitim** (JS braucht den Wert nicht), aber `clean_daily` reicht `min_steps` nicht an `flag_daily` durch (`helpers.R:86-92`) |
| A8 | `DAYS_BACK = 180` | `garmin_fitness.R:58`, Standardwert `helpers.R:135` (explizit übergeben `garmin_fitness.R:252`) | — | **Zufällig**, klein |
| A9 | Tanaka-Formel `208 - 0.7 * age` | `load_recovery.R:23`, `:29` | — | **Zufällig**, klein (eine Hilfsfunktion) |
| A10 | Herzfrequenzreserve-Anteil `pmin(pmax((x - rhr_ref)/(hrmax - rhr_ref),0),1)` und Zonengrenzen `.5 … .9` | `load_recovery.R:74`, `:106`, `:120`, `:136-138`; Grenzen `:33-34`, `:70-73`, `:140` | Innerhalb eines Features gewachsen | **Zufällig** |
| A11 | Garmin-Bänder (Readiness 25/50/75, HRV-Basis) | Template `:152`, `:523`, `:319`; Quelle `garmin_extra.py:103` | Von Garmin definiert | **Legitim**, aber zwei Fundstellen im JS (Text und Farben) |

## B. Logik (Feature 1, 2, 3, 5, 6)

| # | Konzept | Fundstellen | Urteil |
|---|---|---|---|
| B1 | **Rollierendes Mittel** | `garmin_fitness.R:100-105` (`roll_mean`, 7 Tage, mindestens 3), `load_recovery.R:173-180` (`roll_apply`, mit `k`, `fun`, `min_n`, `lag_by`), `dashboard_template.html:207-210` (`roll`, Kommentar „wie roll_mean() in R“) | R-Doppelung **zufällig** (`roll_mean` = `roll_apply(x, 7, mean, 3)`). Die JS-Kopie ist **legitim**: Sie läuft nach dem clientseitigen Ausblenden (`hideBad`, `partial`) in `prepDaily`. Sie braucht einen Gegentest, keine Entfernung. |
| B2 | Zeilen- statt Kalendertage in Rollfenstern | `load_recovery.R:173`, Template `:207`; `validate_daily` warnt bei Lücken nur (`helpers.R:156-165`) | **Zufällig / Risiko.** Richtig nur bei lückenloser Tabelle. |
| B3 | Wochenbildung und Teilwoche | `garmin_fitness.R:465-473`, Template `:651-663` (`partialWeek`, `monday()`, `isoWeek()` `:183-185`) | **Legitim** (R baut PNGs, JS baut interaktive Wochen), verschwindet mit Feature 6 |
| B4 | Ausschluss unvollständiger Tage | `helpers.R:79`, `garmin_fitness.R:408` (`steps_c`), Template `:205-206` (`steps_ok`) | JS-Teil **legitim**, `garmin_fitness.R` verschwindet mit Feature 6 |
| B5 | `clean_daily`-Semantik im JS nachgebaut | `helpers.R:86-92`, Template `:202-203` (`sleep_bad` → `SLEEP_COLS = null`, `rhr_bad` → `resting_hr = null`) | **Legitim** (Schalter `hideBad` ist clientseitig), `SLEEP_COLS` kommt per `META` |
| B6 | Radfahrten erkennen | `merge_rides` exakt `"cycling"` (`helpers.R:27`), `load_recovery.R:105`, `:137`, `garmin_fitness.R:362`; `activity_group` Regex `cycling\|biking\|ride` (`helpers.R:10`) | **Zufällig, mit Verhaltensfolge:** `e_bike` und `indoor_cycling` gelten als „Rad“, werden aber nicht zusammengeführt und nicht als Pendelstrecke geschätzt. |
| B7 | **Newey-West + `qt` + manueller p-Wert** | `load_recovery.R:368-372` (Lag 3), `weather.R:95-99` (Lag 7) | **Zufällig** (gleicher Block, nur Lag und Term-Name unterscheiden sich). Dazu der Faktor `100·(exp(z)−1)` für ln-HRV: `weather.R:97`, `helpers.R:262-264`. |
| B8 | Annotationen im Ausschluss | `weather.R:83` (`ann_note` raus), `helpers.R:250`, `:296` (Anteil annotierter Wochen), `load_recovery.R:340`, `:347` (nur `unrecorded` und `sleep_bad`, **keine** Annotation) | **Zufällig:** `recovery_data` ignoriert `ann_note`. |

## C. Einlesen und Struktur

| # | Konzept | Fundstellen | Urteil |
|---|---|---|---|
| C1 | `col_types` der Aktivitäten-CSV | `garmin_fitness.R:236-241`, `build_dashboard.R:36-41`, `:53-56` | **Zufällig.** `read_act_cache()` gibt es schon (`garmin_fitness.R:236`), `build_dashboard.R` nutzt es nicht. |
| C2 | Doppeltes Einlesen derselben Datei | `build_dashboard.R:36` und `:53` (die zweite Version ist ungemergt, daher läuft `validate_acts` auf anderen Daten als die Auswertung) | **Zufällig** |
| C3 | Zonen-, Puls-, Wetter-, Tages-CSV mit eigenem Schema | Zonen/Puls `garmin_fitness.R:304`, `:324`, `build_dashboard.R:46`, `:49`; Wetter `weather.R:37`, `build_dashboard.R:32`; Tageswerte `garmin_fitness.R:230-234`, `build_dashboard.R:29`, `update_weather.R:6` (uneinheitliche Typen für `sleep_start`) | **Zufällig** |
| C4 | `fx_*`-Spaltennamen | `garmin_extra.py:73`, `garmin_fitness.R:191-192`, `helpers.R:133` (`FX_COLS`) | **Teilweise legitim** (Python/R-Grenze). Drei Stellen müssen synchron bleiben. Ein Test fehlt. |
| C5 | `num()`-Hilfsfunktionen | `garmin_fitness.R:97`, `weather.R:23`, `weather.R:50`, `load_recovery.R:122` | **Zufällig**, klein |
| C6 | **Legacy-PNG-Plots gegen Dashboard** | 6 von 7 Plots haben ein Dashboard-Gegenstück (`garmin_fitness.R:429-522` gegen `dashboard_template.html:123-128`, `:353-377`, `:468`). Plot 6.6 (`aktivitaeten_puls`, `:493-512`) hat **keines**. | **Zufällig**, mit Entscheidungsbedarf (siehe 03) |
| C7 | `helpers.R` mischt Bereinigung und Statistik | Bereinigung `:1-207`, Statistik `weight_trend` `:215`, `adaptation_trends` `:273` | Strukturthema, kein Duplikat |

## D. Innerhalb des JS

| # | Konzept | Fundstellen | Urteil |
|---|---|---|---|
| D1 | `fmtP` zweimal | `dashboard_template.html:554`, `:593` | **Zufällig** |
| D2 | Farbcodes als Hex | z. B. `#D55E00` an `:170`, `:363`, `:387`, `:412`, `:456`, `:543`; `#0072B2` an `:170`, `:356`, `:395`, `:421`, `:429`, `:457` | **Zufällig** |
| D3 | Legenden- und Achsen-Optionen | Legende `:345`, `:358`, `:370`, `:380`, `:390`, `:413`, `:430`, `:453` (`noLegend` `:383`); `ticks` `:346`, `:364`, `:368`, `:375`, `:382` | **Zufällig** |
| D4 | Vorzeichen-Hilfen `sg`/`sgn` | `:324`, `:555`, `:573`, `:595` | **Zufällig**, klein |
| D5 | `DAY` und `MS_DAY` | `:173`, `:249` | **Legitim** (der Block `<weightChange>` wird getrennt getestet) |

## E. Wo die Duplikate Methodik berühren („Methoden-Lücken“)

Die Befunde 1–9 aus dem Plan, den Notion-Abgleich und die in der Durchsicht gefundenen Ursachen zeige ich hier zusammen. Die Prompts dazu stehen in `04-handoff-prompts.md` unter M1 und M2.

| Plan-Befund | Bezug zum Duplikat-Bericht | Prompt |
|---|---|---|
| 1 Beispiel-Geburtsdatum im Kommentar | kein Duplikat | **offen**, siehe Hinweis in 04 |
| 2 „HIIT“ verschieden definiert | Modell `load_recovery.R:232`, Dashboard `helpers.R:12` (gleiches Konzept, zwei Definitionen, vgl. B6) | M1 |
| 3 Erholungs-Intervalle knapp | B7, B8 (gleicher Block wie Wetter, `recovery_data` ohne Annotationen) | M2 |
| 4 Wetter ohne Saison-Adjustierung | B7 | M2 |
| 5 JS-t-Tabelle | A-Familie „Statistik im JS“: `dashboard_template.html:248-263` | M2 |
| 6 Wochentrends ohne Mehrfachtest-Korrektur | B7 (Holm-Behandlung weicht ab) | M2 |
| 7 Zeilen- statt Kalendertage | B2 | S2 (Rolling) |
| 8 Look-ahead bei Erholungs-Index und Referenzpuls | kein Duplikat | M2 (nur dokumentieren) |
| 9 ACWR-Mindestwerte nicht auf der Notion-Seite | kein Duplikat | M1 |

## F. Was ich bewusst **nicht** als Duplikat einstufe
- JS-Rollmittel, JS-Maskierung und JS-Wochenbildung (B1, B3, B5): Sie laufen in der Interaktion nach dem Filtern. R müsste für jede Filterkombination vorrechnen.
- R rechnet, JS rendert: Der Datenvertrag `DAILY`, `ACTS`, `TRENDS`, … (siehe `05-dashboard-build-frontend.md`) ist die gewollte Trennung.
- Das Mehrfach-Berechnen von `trimp_sensitivity` und `pmc_sensitivity` nur für die Konsole (`build_dashboard.R:190`) ist Diagnose, kein Produktivpfad.
