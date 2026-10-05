# Plan 01: Befunde aus der Methodenprüfung beheben

Ausgangspunkt: die Prüfung vom 2026-10-05 (Befunde A1–A6, B7–B12). Jede Phase ist in einer eigenen Session ausführbar. Jede Phase endet mit einem Commit. Reihenfolge: je Phase nur auf den Ergebnissen der vorigen aufbauen.

## Offene Entscheidungen (vor Phase 3, 4, 5 beantworten; Default in Klammern)

| # | Frage | Default |
|---|-------|---------|
| E1 | `sandwich` für Newey-West-Standardfehler. | **entschieden: installiert (2026-10-05)** |
| E2 | Zeiträume ohne Aktivität, aber mit Schritten (z. B. 31.07.–28.08.): als „Last unbekannt“ (NA) behandeln oder per Annotationsdatei (`data/annotations.csv`: von, bis, Art) beschriften? | NA + optionale Annotationsdatei |
| E3 | Pauschale Pendel-Intensität `COMMUTE_HRR`: bei 0,40 lassen oder aus den 6 gemessenen Fahrten ableiten (Mittel ≈ 0,46)? | 0,40 lassen, Sensitivität ausweisen |
| E4 | HFmax: Feldtest oder Brustgurt vorhanden? Der Plan kann den Wert nicht selbst bestimmen. | bis dahin 182 als „angenommen“ beschriften |

## Phase 0: Dokumentations-Recherche (erledigt, Stand 2026-10-05)

Alles lokal geprüft, nichts angenommen.

**Erlaubte APIs (verifiziert):**
- dplyr 1.2.0: `summarise()` wertet Ausdrücke nacheinander aus; ein früher erzeugter Spaltenname überschreibt die Eingangsspalte für spätere Ausdrücke. Das ist die Ursache von A5.
- testthat 3.3.2: `test_that`, `expect_equal`, `expect_error`, `local_reproducible_output`. Verzeichnis `tests/testthat/` existiert noch nicht.
- lmtest 0.9.40 (`coeftest`) installiert. `sandwich` fehlt (E1).
- slider 0.3.0 (`slide_dbl`) und zoo 1.8.11 (`rollapply`) installiert, für kalenderbasierte Rolling-Fenster nutzbar. Die vorhandene `roll_apply()` bleibt sonst Standard.
- garminconnect 0.3.2 im venv `r-garmin`. Vorhandene Methoden (Signatur geprüft): `get_activity_details(activity_id, maxchart=2000, maxpoly=4000)`, `get_activity_hr_in_timezones(activity_id)`, `get_activity_splits(activity_id)`, `get_stats`, `get_heart_rates`, `get_sleep_data`, `get_hrv_data`, `get_weigh_ins`.
- **Nicht verifiziert:** Struktur der Rückgabe von `get_activity_details` (Zeitreihe der Herzfrequenz). Phase 5 beginnt deshalb mit genau einem Live-Aufruf als Spike.

**Anti-Patterns:**
- Keine erfundenen Garmin-Felder. Jedes neue Feld erst an einer gespeicherten Rohantwort belegen.
- Kein `--refresh` zum Testen (180 Tage × mehrere Aufrufe, Rate-Limit). Mit der vorhandenen Cache-Kopie in `data/` arbeiten.
- `set.seed()` nicht im Funktionskörper (verändert den globalen Zustand).
- `data/` und `_outputs/` bleiben git-ignoriert. Kein Geburtsdatum in Ausgaben oder Logs.
- Kein stilles `tryCatch(..., NULL)` für Daten, die gecacht werden.

**Referenzstand für Regressionsvergleich:** vor Phase 1 `Rscript scripts/build_dashboard.R` laufen lassen und `_outputs/fitness_dashboard.html` nach `.claude/scratch/baseline.html` kopieren. Zusätzlich die Skripte `audit.R`, `audit2.R`, `audit3.R` aus dem Session-Scratchpad nach `tests/audit/` übernehmen. Sie liefern die Referenzzahlen aus der Prüfung (TRIMP-Summe 6.449, 286 Einheiten nach Merge, 29 `unrecorded`-Tage, 15 Tage ACWR > 1,3).

---

## Phase 1: Testgerüst und `merge_rides` reparieren (A5)

**Implementieren**
1. `tests/testthat.R` und `tests/testthat/test-helpers.R` anlegen.
2. Test zuerst: zwei Radsegmente am selben Tag (Fixture aus der Prüfung: Dauer 10 und 30 min, avg_hr 100 und 140). Erwartet: eine Fahrt, `avg_hr == 130` (dauergewichtet), `duration_min == 40`.
3. Fix in [helpers.R:36-43](../scripts/helpers.R): `avg_hr` vor der Überschreibung berechnen oder die Dauer unter eigenem Namen (`dur_sum`) führen, danach umbenennen.
4. Zonen gemergter Fahrten: neue Spalte `segment_ids` (Text, `;`-getrennt) in `merge_rides`. `zone_trimp()` ([load_recovery.R:42](../scripts/load_recovery.R)) summiert über alle Segment-IDs statt nur über `first(activity_id)`.
5. Tests für `activity_group`, `sum_na`, `max_na` ergänzen (Randfälle: nur NA, leerer Vektor).

**Verifikation**
- `Rscript -e 'testthat::test_dir("tests/testthat")'` grün.
- Der Test schlägt vor dem Fix fehl (rot → grün belegen).
- `build_dashboard.R` neu laufen lassen: Anzahl Aktivitäten (286 nach Merge) und TRIMP-Summe unverändert, da die 6 gemessenen Fahrten einsegmentig sind.

**Guard:** `merge_rides` nicht umschreiben, nur die Berechnungsreihenfolge korrigieren.

## Phase 2: Eine Bereinigungsfunktion, unvollständige Tage markieren (A6, B7)

**Implementieren**
1. `clean_daily(daily, min_sleep_h = 5, min_rhr = 45)` in `helpers.R`: setzt Schlafspalten bei `sleep_h < min_sleep_h` und Ruhepuls `< min_rhr` auf NA. Schwellen als Konstanten in `META` an das Dashboard geben (JS liest `META.min_sleep_h` statt fest `MIN_SLEEP_H`, [dashboard_template.html:134](../scripts/dashboard_template.html)).
2. Verwendung in `garmin_fitness.R` (Abschnitt 5, Zeile 372) und `build_dashboard.R` (vor `daily_load_recovery`). Damit sind R-Plots, Konsolen-Zusammenfassung und HTML konsistent.
3. Spalte `partial`: `date >= Sys.Date()` oder (`steps < 500` und `sleep_h` fehlt). Teil-Tage fließen nicht in 7-Tage-Mittel, KPIs, 30-Tage-Zusammenfassung ([garmin_fitness.R:500-509](../scripts/garmin_fitness.R)) und ACWR ein. Sie bleiben in den Diagrammen sichtbar (blass) und tragen den Hinweis „vorläufig“.
4. Wochenbalken: laufende Kalenderwoche als „unvollständig“ markieren, nicht als Einbruch zeigen ([dashboard_template.html:404-427](../scripts/dashboard_template.html), `weeks` reicht bis `maxT`).

**Verifikation**
- Test: `clean_daily` mit Fixture (4,9 h bleibt NA, 5,0 h bleibt erhalten; RHR 39 → NA, 45 bleibt).
- 90-Tage-Schrittmittel im HTML = 4.544 (ohne die Teil-Tage 04.10./05.10.), nicht 4.445.
- Grep: kein zweites hartkodiertes `< 5` oder `>= 45` außerhalb von `clean_daily`: `grep -nE "sleep_h *< *5|>= *45|MIN_SLEEP_H *=" scripts/*`.

**Guard:** Die JS-Umschaltung „schlechte Nächte ausblenden“ bleibt erhalten, nur die Schwelle wird zentral.

## Phase 3: Wear-Erkennung und getrennte Lastanzeige (A3, A4, B9)

Voraussetzung: E2 und E3 entschieden.

**Implementieren**
1. [load_recovery.R:104-107](../scripts/load_recovery.R): `unrecorded` nicht mehr nur aus „keine Aktivität“. Neu: `no_wear = steps < 500 & is.na(resting_hr)`; Lücke ≥ `min_gap_days` ohne Aktivität wird in `load_unknown` (Schritte vorhanden, Last unbekannt) und `not_worn` (keine Daten) unterteilt. Beide setzen die Last auf NA. Kürzere Lücken bleiben Nulllast.
2. Optional (E2): `data/annotations.csv` (`from,to,kind`) lesen; Zeilen mit `kind` setzen `load_unknown` explizit. Fehlt die Datei, kein Fehler.
3. ACWR-Varianten ausweisen: Gesamt, nur gemessene Last (`acwr_meas`, existiert in der Prüfung als Idee). Dashboard zeigt `acwr_meas` als zweite Linie neben der Gesamtvariante und Garmins Wert, mit Hinweis „28 % der Last geschätzt“.
4. Pro Einheit `trimp_src` im Dashboard-Hinweis um den Anteil geschätzter Last im gewählten Zeitraum ergänzen.
5. Sensitivitätstabelle in `build_dashboard.R` (Konsole): TRIMP-Summe für HFmax ±10 und `COMMUTE_HRR` 0,3 / 0,4 / 0,5.

**Verifikation**
- Der Zeitraum 31.07.–28.08. erscheint als `load_unknown` (Schritte vorhanden), nicht als `not_worn`.
- Test: synthetische 12-Tage-Lücke mit Schritten → `load_unknown`; ohne Schritte → `not_worn`; 5-Tage-Lücke → Nulllast.
- ACWR-Anzahl `> 1,3` bleibt in derselben Größenordnung (Referenz: 15 Tage).
- Sensitivitätstabelle liefert die Referenzspanne (HFmax 172–190 → TRIMP 7.487–5.827).

**Guard:** Keine Last für unbekannte Zeiträume erfinden. Die Entscheidung E2 nicht stillschweigend ändern.

## Phase 4: HIIT-Erholungsanalyse neu (A1)

Voraussetzung: E1.

**Implementieren**
1. `recovery_summary()` ([load_recovery.R:148-167](../scripts/load_recovery.R)) ersetzen durch `recovery_model()`:
   - `lm(kennwert ~ hiit + wochentag_des_messtags)` je Kennwert.
   - 95-%-Konfidenzintervall mit Newey-West-Standardfehlern (`sandwich::NeweyWest`, Lag 3) via `lmtest::coeftest`.
   - Standardisierte Effektgröße (Cohen d) und Holm-Korrektur über die verbleibenden Kennwerte (`p.adjust(method = "holm")`).
2. Die Readiness-Zeile aus der Tabelle entfernen und als eigene Zeile „nicht unabhängig (enthält Erholungszeit)“ führen.
3. Diagnosetabelle: Anzahl HIIT- und Kontrolltage je Messwochentag. Warnhinweis im Dashboard, wenn eine Zelle leer ist (Positivität verletzt, aktuell Di: 19 gegen 2; Mo/Mi/So: 0).
4. Sensitivität: dieselbe Analyse nur für Messtage Di/Do (aktuell n = 26 gegen 17).
5. `perm_p` entfällt oder wird ohne `set.seed` und mit `withr::with_seed` bzw. lokalem Sichern von `.Random.seed` geführt.
6. [dashboard_template.html:373-381](../scripts/dashboard_template.html) `renderRecovery`: Spalten Diff., 95-%-KI, p (Holm), Hinweistext korrigieren („Hälfte der HIIT-Tage auf Montagen“).

**Verifikation**
- Referenzwerte aus der Prüfung (wochentagadjustiert): Schlaf-Score −6,6 (−10,6…−2,6), Body Battery −9,2, HRV −1,0 (p = 0,33), Ruhepuls +0,9 (p = 0,17). Abweichung nur durch HAC-Standardfehler und Holm erwartet.
- Test: Fixture mit bekanntem Effekt und AR(1)-Rauschen; das KI deckt den wahren Effekt ab.
- Grep: `grep -n "set.seed" scripts/` nur außerhalb von Funktionskörpern.

**Guard:** Keine kausale Sprache („HIIT senkt…“). Der Hinweistext bleibt „Zusammenhang, kein Beweis“.

## Phase 5: Herzfrequenz-Artefakte und HFmax (A2)

Voraussetzung: E4.

**Spike (zuerst, ein einziger Live-Aufruf)**
1. `get_activity_details` für die Einheit vom 11.05.2026 (Spitzenpuls 223) aufrufen und die Rohantwort in `.claude/scratch/activity_details.json` sichern. Belegen, wo die Herzfrequenz-Zeitreihe liegt (Metrik-Deskriptoren). Ohne diesen Beleg nicht weitermachen.

**Implementieren (nur wenn der Spike die Zeitreihe zeigt)**
1. `fetch_hr_peak(api, activity_id)` in `garmin_extra.py`: robuster Spitzenpuls (99,5-%-Perzentil der Samples, ohne Werte, die sich um mehr als 30 bpm innerhalb einer Sekunde ändern). Ergebnis in `data/garmin_activity_hr.csv` cachen (nur neue Einheiten abfragen, wie in `update_zones`).
2. `build_dashboard.R`: `n_exceed` aus dem robusten Spitzenpuls statt `max_hr` berechnen. Hinweis im Dashboard entsprechend.
3. `athlete_profile()`: Label „gemessen“ nur, wenn `HRMAX` gesetzt ist (E4), sonst „angenommen“. Garmins HFmax (2 × Z1-Untergrenze = 178) im selben Kasten neben dem Profilwert zeigen.
4. Dashboard-Zonenkarte: ein Satz, der beide Zonensysteme (Garmin %HFmax gegen HFR) erklärt.

**Verifikation**
- Die Einheit mit 223 bpm hat robusten Spitzenpuls unter 200.
- Anzahl Einheiten über HFmax sinkt oder bleibt gleich, steigt nie (Vergleich mit Referenz 15 von 102).
- Cache-Datei hat eine Zeile je Einheit mit Puls, keine Duplikate: `anyDuplicated(activity_id) == 0`.

**Guard:** Keine automatische Anpassung von HFmax an Artefakte. Der Wert bleibt eine bewusste Eingabe.

## Phase 6: Cache-Integrität und stabile Referenz (B11)

**Implementieren**
1. `_try()` in [garmin_extra.py:11-15](../scripts/garmin_extra.py): bis zu 3 Versuche mit Wartezeit 1, 2, 4 s. Rückgabe unterscheidet „Fehler“ (Ausnahme) von „keine Daten“ (leere Antwort).
2. `extra_day()` liefert zusätzlich `fx_sleep`, `fx_hrv`, `fx_ready`, `fx_status` (`TRUE` = Aufruf gelungen). `fetch_day` ([garmin_fitness.R:151-186](../scripts/garmin_fitness.R)) schreibt sie als Spalten.
3. `update_daily` ([garmin_fitness.R:237-260](../scripts/garmin_fitness.R)): Tage mit mindestens einem `fx_*` gleich `FALSE` im Fenster nachladen. Für Alt-Cache ohne `fx_*`-Spalten nur Tage mit fehlendem Schlaf der letzten 14 Tage nachladen.
4. `validate_daily()` und `validate_acts()` in `helpers.R`: lückenlose Datumsfolge, keine doppelten Schlüssel, Wertebereiche (Schritte ≥ 0, Ruhepuls 30–100, Schlaf 0–16 h). Warnung mit Zahl der Verstöße, kein Abbruch.
5. Stabile Ruhepuls-Referenz: `RHR_REF` aus `~/.Renviron`, sonst beim ersten Lauf Median berechnen und in `data/profile.json` speichern. Neuberechnung nur mit `--recalc-profile`. Ersetzt [build_dashboard.R:43](../scripts/build_dashboard.R).

**Verifikation**
- Test: simulierter Ausnahmefall in `_try` (Python-Test mit Dummy-API) → `fx_* = FALSE`; „keine Daten“ → `fx_* = TRUE`, Wert NA.
- Zwei aufeinanderfolgende `build_dashboard.R`-Läufe liefern identische TRIMP-Summen (heute ändert sich `rhr_ref` mit dem Fenster).
- Grep: `grep -n "tryCatch" scripts/*.R` zeigt keinen Treffer mehr, der Cache-Daten mit `NULL` füllt, ohne zu markieren.

**Guard:** Keinen Voll-Refresh auslösen. Migration des Cache über die neue Spaltenprüfung (wie bei den HRV-Spalten).

## Phase 7: Gewichtstrend und Plot-Korrekturen (B10, B12)

**Implementieren**
1. Gewichtstrend in `build_dashboard.R`: `loess` (oder gleitender Median) über die Wiegungen, Ausgabe von Trendwert und 95-%-Band. KPI [dashboard_template.html:221-247](../scripts/dashboard_template.html): Differenz der Trendwerte am Anfang und Ende des Zeitraums mit KI; bei KI über Null „keine belastbare Veränderung“. Weniger als 6 Wiegungen im Zeitraum: kein Trend, nur Einzelwerte.
2. [garmin_fitness.R:463-466](../scripts/garmin_fitness.R): loess je Aktivitätsgruppe statt über alle Typen, nur für Gruppen mit mindestens 8 Einheiten mit Puls. Sonst Trendlinie entfernen.

**Verifikation**
- Aktuelles Fenster (4 Wiegungen in 90 Tagen) zeigt keinen Trend, nur Punkte.
- Gesamtes Fenster (16 Wiegungen) zeigt Trend mit Band.

## Phase 8: Abschlussverifikation

1. Alle Tests: `Rscript -e 'testthat::test_dir("tests/testthat")'`.
2. `tests/audit/audit*.R` erneut laufen lassen und gegen die Referenzzahlen aus Phase 0 abgleichen. Jede Abweichung erklären (beabsichtigt oder Regression).
3. Anti-Pattern-Grep: `weighted.mean(`-Nutzung nach Überschreibung, `set.seed` in Funktionen, hartkodierte Schwellen, `tryCatch(... NULL)` ohne Markierung.
4. Dashboard im Browser öffnen: Konsole ohne Fehler, Teil-Tag-Markierung, Wochenbalken, Erholungstabelle, Zonenkarte, Gewichts-KPI. Schmales Fenster (375 px) prüfen.
5. Baseline-HTML gegen neues HTML vergleichen: nur die beabsichtigten Zahlen weichen ab.
6. Kurzer Abschlussbericht je Befund (A1–B12): behoben, abgemildert oder bewusst offen.
