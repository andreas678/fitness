# Handoff-Prompts (Pathfinder Phase 4)

Jeder Block ist kopierfertig für `/make-plan`. Grundlage: `02-duplication-report.md` (Belege) und `03-unified-proposal.md` (Ziel). Ich habe nichts davon umgesetzt.

Hinweis: Alle Zeilenangaben stammen von `main` @ `747898f`. Wenn der Code sich bewegt hat, zuerst die Fundstelle mit `grep` neu finden.

---

## S3 – `garmin_fitness.R` auf Abruf und Cache beschränken
**Vorab klären (Entscheidung der Nutzerin oder des Nutzers):** PNG-Exporte und `--demo` streichen? Plot 6.6 ins Dashboard übernehmen oder streichen?

```
/make-plan Reduziere scripts/garmin_fitness.R auf Abruf, Cache und Validierung. Ziel-Einstiegspunkt bleibt `Rscript scripts/garmin_fitness.R` (Dateiname und README-Befehle bleiben gültig).

Zu löschen (Fundstellen auf main @ 747898f):
- Demo-Modus: garmin_fitness.R:342-375 (demo_data, set.seed 42), Argument DEMO (:54-56), PREFIX (:76), der Demo-Zweig in :378-381 und :402.
- Datenaufbereitung für Plots: :404-425.
- Plots 6.1-6.7: :429-522, Speichern :526-531, kombiniertes PNG :532-542.
- Konsolen-Zusammenfassung "Letzte 30 Tage": :545-555.
- Konstanten, die dann nirgends mehr gebraucht werden: PLOT_DAYS (:58/59), STEP_GOAL (:59/60), GROUP_COLORS (:78-85), roll_mean (:100-105). Vorher mit grep prüfen, dass sie in tests/ und scripts/ nirgends vorkommen.
- README.md: Abschnitte zu PNG-Ausgabe und --demo (README:11, :44, :53, :114) anpassen.

Entscheidungen, die du vor dem Start bestätigen lässt:
1. PNG-Export und --demo wirklich streichen? (Belege: build_dashboard.R:20-22 bindet garmin_fitness.R nicht ein; tests/ verweisen nicht darauf.)
2. Plot 6.6 (aktivitaeten_puls, :493-512, keine Entsprechung im Dashboard) ins Dashboard übernehmen oder streichen?

Siehe PATHFINDER-2026-10-05/01-flowcharts/06-legacy-plots.md (Plot-gegen-Dashboard-Tabelle) und 01-abruf-cache.md (was bleiben muss).

Anti-Pattern-Wächter:
- Keine Feature-Flags wie --plots, die den alten Pfad optional halten.
- Keine neue Datei für die gelöschte Logik.
- Abruf, Cache, fx_*-Flags und die Aufrufe update_daily/update_activities/update_weight/update_zones/update_hr/update_weather_env (:388-394) dürfen sich nicht ändern.
- Verifikation: `Rscript scripts/garmin_fitness.R` läuft durch (mit gültigem Login oder mit vorhandenem Cache), `Rscript scripts/build_dashboard.R` erzeugt dasselbe Dashboard wie vorher (Diff der JSON-Konstanten), `Rscript tests/testthat.R` grün.
```

---

## S1 – Eine Quelle für Konstanten, das JS liest `META`

```
/make-plan Lege die geteilten Konstanten an einer Stelle ab und lass das Dashboard sie aus META lesen. Ziel-Komponente: ein Konstanten-Block am Anfang von scripts/helpers.R (wird schon von garmin_fitness.R:107, build_dashboard.R:20 und update_weather.R eingebunden). Einziger Einstiegspunkt ins JS: das bestehende `meta` in scripts/build_dashboard.R:136-157 (Muster existiert: min_sleep_h, sleep_cols, tau_fit/tau_fat via formals(fitness_fatigue)).

Zu ändernde Stellen:
- RIDE_GAP_MIN/RIDE_MIN_MIN: garmin_fitness.R:61-62 (oder nach S3 nur noch :411 entfällt), build_dashboard.R:25-26; Standardwerte helpers.R:25 sollen auf dieselben Variablen verweisen; Literale 30,3 in tests/testthat/test-helpers.R:13,24,31,38,43,50 und tests/audit/audit.R:13, audit2.R:6,19, audit3.R:6, audit_b8.R:6, audit_pmc.R:6 durch die Konstanten ersetzen.
- STEP_GOAL und GROUP_COLORS: garmin_fitness.R:60,78-85 (entfallen mit S3) gegen dashboard_template.html:173 und :170 -> META.step_goal, META.group_colors.
- ACWR-Band 0.8/1.3: dashboard_template.html:311-312, :393-394, :510 und Text :134 -> eine Konstante in R, über META.acwr_band; die Notion-Seite nennt den Bereich einen groben Richtwert, die Beschriftung bleibt.
- Hitzetag 30 °C: dashboard_template.html:537 (HEAT_C) -> META.heat_c, definiert in weather.R.
- META.min_rhr und META.ride_min_min (build_dashboard.R:139, :145) werden vom JS nicht gelesen: entweder im JS nutzen oder entfernen.
Siehe PATHFINDER-2026-10-05/02-duplication-report.md Tabelle A und 01-flowcharts/05-dashboard-build-frontend.md (Datenvertrag).

Anti-Pattern-Wächter:
- Kein YAML/JSON-Konfigurationsformat, keine Registry, keine neue Datei.
- Der Block <dateRange> (template :216-240) und <weightChange> werden von tests/js/*.mjs per Regex gelesen: Marker nicht verschieben.
- Garmin-definierte Bänder (Training Readiness 25/50/75, template :152, :523) bleiben im JS, sie gehören Garmin.
- Ergänze einen Test, der im Template keine Literale 0.8/1.3, 10000, 30 für diese Konzepte mehr zulässt (Vorbild: tests/js/test_date_range.mjs).
```

---

## S4 – Ein Einlesepfad je CSV

```
/make-plan Zentralisiere das Einlesen der data/*.csv. Es gibt schon read_daily_cache() (garmin_fitness.R:227-235) und read_act_cache() (:236-241); verschiebe sie nach scripts/helpers.R und ergänze gleichartige Leser für Zonen, Puls, Gewicht und Wetter. Einziger Einstiegspunkt je Datei: die jeweilige read_*-Funktion.

Zu ändernde Aufrufstellen:
- build_dashboard.R:29 (Tageswerte), :36-41 (Aktivitäten), :44-49 (read_opt: Zonen, Gewicht, Puls), :53-56 (Aktivitäten ein zweites Mal), :32 (Wetter; weather.R:37 hat das Schema auch).
- update_weather.R:6 (Tageswerte mit col_guess; Typen für sleep_start weichen ab).
- garmin_fitness.R:230-234, :238-241, :304, :324 nutzen danach die verschobenen Leser.
Zwei Einleseläufe derselben Aktivitäten-CSV (build_dashboard.R:36 und :53) werden zu einem; validate_acts soll bewusst entweder auf den rohen oder den zusammengeführten Daten laufen und das im Kommentar sagen.
Siehe 02-duplication-report.md Tabelle C und 01-flowcharts/01-abruf-cache.md (Spaltenschemata).

Anti-Pattern-Wächter:
- Keine Schema-Registry und kein Spaltentyp-Framework, nur Funktionen mit festen col_types.
- Verhalten der Cache-Aktualisierung (days_to_fetch, fx_*) nicht anfassen.
- Verifikation: Dashboard vor und nach dem Umbau byte-gleich bis auf den Zeitstempel (META.built), `Rscript tests/testthat.R` grün.
```

---

## S2 – Ein Rollmittel auf Kalendertagen

```
/make-plan Vereinheitliche das rollierende Mittel in R auf Kalendertage und gib dem JS-Gegenstück einen Gegentest. Ziel-Komponente: roll_apply (load_recovery.R:173-180) wandert nach scripts/helpers.R und rechnet über die Datumsspalte (fehlende Kalendertage zählen als NA), nicht über Zeilen.

Zu ändernde Stellen:
- garmin_fitness.R:100-105 (roll_mean, 7 Tage, mindestens 3 Werte) entfällt (oder mit S3 gelöscht), Aufrufe :409-410 ersetzen.
- load_recovery.R:173 und alle Aufrufe in daily_load_recovery (:253-268, :276-283) auf die datumsbasierte Variante umstellen.
- JS bleibt (dashboard_template.html:207-210, `roll`), weil es nach clientseitigem Maskieren (hideBad, partial, prepDaily :199-214) läuft. Ergänze einen Test, der JS-roll und R-roll_apply auf denselben Eingaben mit Datumslücken vergleicht (Vorbild: der bestehende Browser-gegen-R-Abgleich der Gewichtsänderung in tests/js/test_weight_change.mjs).
Siehe 02-duplication-report.md B1, B2 und 01-flowcharts/03-belastung-erholung.md.

Anti-Pattern-Wächter:
- Kein zweites Rollmittel "für Sonderfälle" neben roll_apply.
- Mindestwerte (7 Tage mind. 5, 28 Tage mind. 14 für ACWR; mind. 3 für das Dashboard-Mittel) bleiben unverändert.
- Vergleiche acwr, ctl, atl, tsb, rhr_base, rec_index vor und nach der Änderung auf den echten Daten (tests/audit/audit_pmc.R und audit2.R); Abweichungen nur dort erlaubt, wo data/garmin_daily.csv Datumslücken hat, und diese ausweisen.
```

---

## S5 – Inferenz-Hilfsfunktion und gleiche Ausschlussregeln

```
/make-plan Ziehe den gemeinsamen Block "Newey-West-Standardfehler, qt-Intervall, manueller p-Wert" in eine Funktion nw_effect(fit, term, lag) in scripts/helpers.R. Aufrufer: recovery_model (load_recovery.R:358-373, :368-372) und weather_effects (weather.R:94-99). Dazu eine Zeile/Funktion für die HRV-Rückrechnung 100*(exp(z)-1), die in weather.R:97 und helpers.R:262-264 steht.

Zusätzlich: recovery_data (load_recovery.R:337-349, Filter :340, :347) berücksichtigt keine Annotationen; weather_effects (weather.R:83) und adaptation_trends (helpers.R:250, :296) tun es. Entscheide mit mir, ob recovery_data annotierte Tage ausschließt (Verhaltensänderung: HIIT-Erholung rechnet dann mit weniger Tagen), und dokumentiere die Entscheidung auf der Notion-Seite "Methoden" (ich ändere Notion nicht selbst).
Behalte: Lag 3 gegen Lag 7, Holm-Familie, Mindest-n je Modell. Das sind begründbare Spezialisierungen; schreibe die Begründung jeweils als Kommentar neben den Aufruf.
Beobachtung am Rande: recovery_design(x) wird in load_recovery.R:359 zweimal berechnet.
Siehe 01-flowcharts/04-inferenz-module.md (Abweichungstabelle) und 02-duplication-report.md B7, B8.

Anti-Pattern-Wächter:
- Keine Klasse und kein generisches "Inferenz-Framework", eine Funktion.
- Ausgabespalten von recovery_model und weather_effects bleiben unverändert (das Template liest sie, dashboard_template.html:551-557, :599-610).
- Verifikation: tests/testthat/test-recovery.R und test-weather.R grün; Zahlen für Intervalle und p-Werte vor und nach dem Umbau identisch (ohne die Annotationsentscheidung).
```

---

## S6 – Kleinkram in einem Durchgang

```
/make-plan Räume in einem Durchgang vier kleine Duplikate auf.
1. Rad-Erkennung: Eine Funktion is_ride(type_key) statt exaktem "cycling" (helpers.R:27 merge_rides, load_recovery.R:105 und :137, garmin_fitness.R:362 entfällt mit S3) und der Regex cycling|biking|ride (helpers.R:10 activity_group). Zur Entscheidung vorlegen: Sollen indoor_cycling und mountain_biking zusammengeführt und als Pendelstrecke geschätzt werden? Heute gelten sie als "Rad" (Regex), werden aber nicht zusammengeführt. E-Bike-Typen treffen die Regex nicht (e_bike_fitness landet in "Gym / HIIT" durch die Regex fitness, e_bike_mountain in "Sonstiges"); ob sie als Rad gelten sollen, wäre eine eigene Entscheidung.
2. Herzfrequenzreserve und Tanaka: hrr_frac(x, prof) ersetzt die Inline-Kopien load_recovery.R:74, :106, :120, :136-138; tanaka_hrmax(age) ersetzt :23 und :29; die Zonengrenzen c(.5,.6,.7,.8,.9) stehen einmal (:33-34, :70-73, :140).
3. JS: fmtP einmal (dashboard_template.html:554 und :593), Farben als PALETTE statt Hex-Literalen (z. B. #D55E00 an :170, :363, :387, :412, :456, :543), gemeinsame Legenden- und Achsenoptionen (:345, :358, :370, :380, :390, :413, :430, :453; noLegend :383), sg/sgn einmal (:324, :555, :573, :595).
4. clean_daily (helpers.R:86-92) soll min_steps an flag_daily durchreichen.
Siehe 02-duplication-report.md A9, A10, B6, D1-D4.

Anti-Pattern-Wächter:
- Die Blöcke <dateRange> (template :216-240) und <weightChange> unverändert lassen, die Tests lesen sie per Regex.
- DAY und MS_DAY (template :173, :249) bleiben getrennt (der Block wird eigenständig getestet).
- Keine Verhaltensänderung außer Punkt 1, und die nur nach Bestätigung.
- tests/testthat und tests/js grün; Dashboard-Ausgabe unverändert.
```

---

## M1 – Notion-Seite „Methoden“ und Code angleichen
Ich ändere Notion nicht. Dieser Prompt erzeugt nur einen Änderungsvorschlag.

```
/make-plan Erstelle eine Änderungsliste für die Notion-Seite "Methoden" (https://app.notion.com/p/3f04ec0eefcb811b8b84dca07190a51f) gegen den Code. Schreibe den Text als Entwurf in eine lokale Datei, ändere Notion nicht.

Ergänzen (alle mit Quelle im Code):
- ACWR-Mindestwerte: mindestens 5 von 7 Tagen (Akut) und 14 von 28 (Chronisch), Chronisch muss mindestens 1 sein, sonst kein ACWR (load_recovery.R:260-262).
- Definition von "HIIT" im Erholungsmodell: nur type_key == "hiit" (load_recovery.R:232); das Dashboard-KPI und die Gruppe "Gym / HIIT" zählen zusätzlich Kraft, Cardio, Fitness (helpers.R:12). Entscheide, welche Definition gelten soll, und gleiche an.
- Newey-West-Lags: 3 (HIIT, load_recovery.R:368) und 7 (Temperatur, weather.R:95), mit Begründung.
- Browser-Berechnung der Gewichtsänderung nutzt eine feste t-Tabelle, ab df > 30 den Wert 2,0 (dashboard_template.html:248-263).
- Zeilen- statt Kalendertage in Rollfenstern, gültig nur bei lückenloser Tabelle (load_recovery.R:173, template :207) – entfällt, wenn S2 umgesetzt ist.
- Die 90-%-Deckung des Intervalls im Simulationstest ist etwas zu optimistisch; ausdrücklich als solche einordnen.
- Der Kommentar mit dem Beispiel-Geburtsdatum in load_recovery.R:6: entscheide mit mir, ob er geändert wird (siehe Hinweis unten).

Anti-Pattern-Wächter: Keine Behauptungen ohne Quelle im Code; keine Änderung an Notion ohne meine Freigabe.
```

---

## M2 – Statistische Lücken schließen (Prioritätenliste, keine Umsetzung)

```
/make-plan Plane die Schließung der statistischen Lücken, einzeln priorisiert. Für jede Lücke: Problem, kleinste Korrektur, Test auf simulierten Daten, erwartete Wirkung. Setze nichts davon ohne meine Freigabe um.

1. Wetter-Effekt (weather.R:74-105): Saison fehlt als Störgröße. Kleinste Korrektur: Zeittrend oder Monat bzw. Trainingslast als Kovariable, Vorher/Nachher-Vergleich.
2. Wochentrends (helpers.R:240-319): Drei Kennwerte (Ruhepuls, HRV, Puls im Schlaf) bekommen Urteile ohne Mehrfachtest-Korrektur; das Intervall nutzt einfaches lm bei 8-12 Wochenmitteln. Prüfe Holm über die drei Kennwerte (und beide Fenster) und eine autokorrelations-robuste Variante.
3. HIIT-Erholung (load_recovery.R:358-373): Cohen-d nutzt die gepoolte SD ohne Adjustierung (:370); Newey-West behandelt Kalenderlücken als aufeinanderfolgend (:356-357); nur 2 von 7 Wochentagen tragen die Adjustierung (recovery_design :396-401). Bewerte, ob ein Block-Bootstrap oder ein Zeitreihenindex die Lücken besser behandelt.
4. Gewichtsänderung im Browser (dashboard_template.html:248-263): feste t-Tabelle; vergleiche mit R-qt und ergänze einen Test (Muster: tests/js/test_weight_change.mjs).
5. Erholungs-Index (load_recovery.R:316-322) und Referenz-Ruhepuls (build_dashboard.R:61): SD, Korrelation und Referenz stammen aus dem Gesamtzeitraum (Look-ahead). Nur dokumentieren, nicht ändern, solange es keine Ergebnisdaten gibt.
6. Neue Auswertungen, die bislang fehlen (zoo, slider, lmtest sind installiert, aber ungenutzt; acf, ccf, cor.test fehlen): Lag-Korrelationen zwischen Last (Vortag) und Ruhepuls/HRV mit Autokorrelation, ACF der Residuen zur Prüfung von Newey-West. Nur als Vorschlag mit Aufwand.
Siehe 02-duplication-report.md Abschnitt E und 01-flowcharts/04-inferenz-module.md.

Anti-Pattern-Wächter:
- Jede Korrektur zuerst auf simulierten Daten mit bekanntem Effekt prüfen (Muster: Test für recovery_model), nicht nur auf den echten Daten.
- Keine neuen Pakete ohne Begründung; sandwich ist nirgends als Abhängigkeit deklariert (kein DESCRIPTION/renv.lock): vorher klären.
```

---

## Offene Entscheidung außerhalb der Prompts
`load_recovery.R:6` enthält im Kommentar ein Geburtsdatum (`26-07-1974`) als Beispiel. Es steht im Working Tree und in der Git-Historie (laut Explore-Bericht in den Commits `55d3798`, `cf67b20`). Ist das Datum fiktiv, genügt ein Hinweis im Kommentar. Ist es echt, wäre das Umschreiben der Historie ein eigener, bewusst zu treffender Schritt. Das habe ich nicht angefasst.
