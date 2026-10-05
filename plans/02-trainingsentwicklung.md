# Plan 02: Trainingsentwicklung (Fitness-Ermüdungs-Modell und Anpassungs-Trends)

Ausgangspunkt: die Frage nach einem Index für den Trainingserfolg (2026-10-05). Ein einzelner Erfolgs-KPI ist mit diesen Daten nicht seriös: VO₂max steht bei 45,2 still (nur 30 Werte), es gibt nur 6 Radfahrten mit Puls über 20 min, keine Leistungsmessung. Gebaut werden deshalb zwei Dinge, die sich ehrlich belegen lassen:

1. **Aufbau und Ermüdung** (Banister/PMC): „Fitness“ (CTL, lange Zeitkonstante), „Ermüdung“ (ATL, kurze) und „Form“ (TSB = Differenz), gerechnet aus der vorhandenen TRIMP-Last.
2. **Anpassungs-Trends**: Wochentrend von Ruhepuls, HRV (ln) und Puls im Schlaf mit Konfidenzintervall.

Jede Phase ist in einer eigenen Session ausführbar und endet mit einem Commit auf einem Branch (`phase10-…`). Vorgehen wie in Plan 01: Tests zuerst, Nachrechnen gegen die vorige Fassung, Merge nach `main` nur auf Zuruf.

## Phase 0: Befunde aus der Dokumentationsprüfung (erledigt, nur lesen)

**Vorhandene Bausteine (nicht neu erfinden, wiederverwenden):**

| Baustein | Ort | Verwendung |
|---|---|---|
| `roll_apply(x, k, fun, min_n, lag_by)` | `scripts/load_recovery.R:173` | gleitende Fenster mit Mindestanzahl |
| `daily_load_recovery(daily, acts_s)` | `scripts/load_recovery.R:182` | liefert `load`, `load_meas`, `load_est`, `unrecorded`, `no_wear`, `load_unknown`, `partial`; Last unbekannter Tage ist **NA**, nicht 0 |
| `clean_daily(d, extra_cols)` | `scripts/helpers.R:86` | maskiert Artefakt-Ruhepuls und ungültige Nächte (`NA`) |
| `weight_trend` | `scripts/helpers.R:215` | Muster für eine getestete Trendfunktion mit Mindestanzahl und Konfidenzband |
| `mk`, `setData`, `baseOpts`, `gridX`, `noLegend` | `scripts/dashboard_template.html` (`mk("c-acwr"…)` ab Zeile 329, `setData` Zeile 383) | Chart-Muster |
| `updateLoadCharts(d, L)` | `scripts/dashboard_template.html:404` | Stelle, an der Last-Grafiken je Zeitraum befüllt werden |
| `daily`-Auswahl, `meta`-Liste | `scripts/build_dashboard.R` (`select(date, …)`, `meta <- list(…)`) | neue Spalten und Kennzahlen hier eintragen |
| Testmuster | `tests/testthat/test-signals.R`, `test-load.R` | synthetische Daten mit bekanntem Ergebnis |

**Verwendete Formeln (Standard, nicht erfunden):**
- Exponentiell gewichtetes Mittel: `X_t = X_{t-1} + (L_t − X_{t-1}) · (1 − exp(−1/τ))`, mit τ = 42 Tage (CTL, „Fitness“) und τ = 7 Tage (ATL, „Ermüdung“).
- Form des Tages t: `TSB_t = CTL_{t-1} − ATL_{t-1}` (Werte vom Vortag, so rechnen TrainingPeaks und Intervals.icu).
- Sprungantwort als Testwert: Nach einem Sprung der Last von 0 auf L erreicht ATL nach 7 Tagen `L · (1 − e^{-1}) = 0,632 · L`, CTL nach 42 Tagen ebenso.

**Zu beachten (Grenzen der Methode):**
- TRIMP ist nicht TSS. Die TrainingPeaks-Schwellen für „Form“ (z. B. −30 bis +5) gelten für TSS und übertragen sich nicht. **Keine absoluten Zonen** zeigen, nur die Nulllinie.
- CTL misst aufgebaute **Trainingslast, nicht gemessene Leistung**. Der Name „Fitness“ gehört in Anführungszeichen und in einen erklärenden Hinweis.
- 34 % der Last sind geschätzt (Pendelfahrten), 29 Tage Last sind unbekannt (Segeltörn). Beides muss in der Darstellung sichtbar bleiben.

## Entscheidungen (vor Phase 1 beantworten; Default in Klammern)

| # | Frage | Default |
|---|-------|---------|
| F1 | Zeitkonstanten 42 und 7 Tage (Standard) oder andere? | 42 / 7 |
| F2 | Tage mit unbekannter Last (Segeltörn, Uhr nicht getragen) und der unvollständige heutige Tag: Zustand **einfrieren** (kein Update, Tage markieren) oder mit dem Median der gemessenen Last auffüllen? | einfrieren und markieren; die andere Variante nur als Sensitivität in der Konsole |
| F3 | Trendfenster für Phase 3: letzte 12 Wochen, vollständige Wochen mit mindestens 4 gültigen Tagen? | 12 Wochen, ≥ 4 Tage |
| F4 | Wochen, die überwiegend in annotierten Zeiträumen liegen (Segeltörn), aus dem Trend ausschließen? | ja (ab 50 % annotierter Tage) |

## Phase 1: Fitness-Ermüdungs-Modell in R (Test zuerst)

**Was zu tun ist**
- Neue Funktion `fitness_fatigue(load, usable, tau_fit = 42, tau_fat = 7, init_days = 14)` in `scripts/load_recovery.R`. `load` ist die Tageslast (NA erlaubt), `usable` ist ein logischer Vektor („Last bekannt und Tag vollständig“). Rückgabe: Tabelle mit `ctl`, `atl`, `tsb`, `pmc_gap` (Zustand an diesem Tag eingefroren) und `pmc_warmup` (die ersten `tau_fit` Tage).
- Start: Anfangswert = Mittel der ersten `init_days` nutzbaren Tage (kein Start bei 0, das ergäbe eine künstliche Aufbauphase).
- Einfrieren: an Tagen mit `usable == FALSE` bleibt der Zustand wie am Vortag, `pmc_gap = TRUE`. Echte Ruhetage haben Last 0 und zählen als bekannt (`daily_load_recovery` setzt sie schon so).
- In `daily_load_recovery` am Ende die Spalten `ctl`, `atl`, `tsb`, `pmc_gap`, `pmc_warmup` ergänzen (Nutzbarkeit: `!unrecorded & !partial`).
- Sensitivitätsfunktion `pmc_sensitivity(dl)`: CTL/ATL am letzten Tag unter „einfrieren“, „Median auffüllen“ und „0 setzen“ (nur zum Ausweisen der Spannweite).

**Tests zuerst** (neue Datei `tests/testthat/test-pmc.R`, Muster aus `test-signals.R`):
1. Konstante Last L: CTL und ATL konvergieren gegen L, TSB gegen 0.
2. Sprungantwort: Nach 7 Tagen Last L (vorher 0, Start bei 0) ist ATL = `L·(1−exp(−1))`, nach 42 Tagen CTL ebenso (Toleranz 1e-6).
3. Form nutzt Vortagswerte: `tsb[t] == ctl[t-1] − atl[t-1]`.
4. Einfrieren: Eine NA-Lücke ändert den Zustand nicht und setzt `pmc_gap`; danach läuft die Rechnung vom eingefrorenen Wert weiter.
5. Anfangswert: Bei konstanter Last von 50 beginnt CTL bei 50 (kein Einschwingen); `pmc_warmup` ist für genau `tau_fit` Tage TRUE.
6. Kein Zahlenverlust: Wenn alle Tage nutzbar sind, hat die Ausgabe keine NA.

**Verifikation:** Alle Tests rot, dann grün. Auf den echten Daten: CTL am letzten Tag und Spannweite aus `pmc_sensitivity` in der Konsole ausgeben und im Ergebnisbericht festhalten.

**Anti-Pattern:** Last NA nicht in 0 umwandeln (`coalesce(load, 0)` für unbekannte Tage ist verboten); keine TSS-Schwellen; keine zweite Rolling-Funktion neben `roll_apply` erfinden, wenn `roll_apply` reicht (die EWMA ist rekursiv und eine eigene Schleife, das ist erlaubt).

## Phase 2: Dashboard-Karte „Aufbau und Ermüdung“

**Was zu tun ist**
- `build_dashboard.R`: `ctl`, `atl`, `tsb`, `pmc_gap`, `pmc_warmup` in die `daily`-Auswahl, `ctl/atl/tsb` auf 1 Nachkommastelle runden, `pmc_gap`/`pmc_warmup` als Integer. In `meta` Zeitkonstanten und Sensitivitätsspanne ablegen. Konsolenzeile: aktuelle Werte und Spannweite.
- `dashboard_template.html`: neue Karte nach der ACWR-Karte. Ein Liniendiagramm (CTL, ATL) und darunter ein Balkendiagramm (Form, über/unter Null verschieden gefärbt). Muster: `mk("c-acwr", …)` und der Eintrag in `updateLoadCharts`. Tage mit `pmc_gap` und `pmc_warmup` blass markieren, wie unvollständige Tage in den bestehenden Grafiken. KPI-Kachel „Form“ (Wert und Richtung der letzten 7 Tage).
- Erklärender Hinweis (`.sub` und `.note`): „Fitness“ = aufgebaute Trainingslast, nicht gemessene Leistung; Form = Fitness minus Ermüdung von gestern; Anteil geschätzter und unbekannter Last im Zeitraum.
- Die Reihe wird über die gesamte Historie in R gerechnet; der Zeitraum-Filter im Dashboard schneidet nur aus.

**Verifikation:** Bestehende Spalten der Nutzlast sind byte-gleich zur vorigen Fassung (Vergleich im Git-Worktree wie in Plan 01); Konsolenwerte stimmen mit dem Test überein; Dashboard im Browser prüfen (Karte sichtbar, keine Konsolenfehler, 375-px-iframe ohne horizontales Scrollen).

**Anti-Pattern:** keine absoluten Zonen oder Ampel für „Form“; keine Aussage „Fitness steigt = du wirst besser“.

## Phase 3: Anpassungs-Trends in R (Test zuerst)

**Was zu tun ist**
- Neue Funktion `adaptation_trends(daily, weeks = 12, min_days = 4, max_ann_share = 0.5)` in `scripts/helpers.R` (neben `weight_trend`). Eingang: bereinigte Tageswerte (`clean_daily`) mit `resting_hr`, `hrv_night` (als ln), `sleep_hr`.
- Je Kennwert: Wochenmittel (Montag-Wochen), nur vollständige Wochen mit mindestens `min_days` gültigen Tagen und höchstens `max_ann_share` annotierter Tage; die letzten `weeks` Wochen. Trend = Steigung der Wochenmittel per `lm` (Woche als Index) mit 95-%-Konfidenzintervall (t-Verteilung), Mindestens 6 Wochen, sonst NA.
- Ausgabe: Wochenreihe (`week`, `value`) und je Kennwert `slope`, `lo`, `hi`, `n_weeks`, `verdict` (`steigend`/`fallend`/`kein klarer Trend`, je nachdem ob das Intervall die Null einschließt). HRV-Steigung als Prozent pro Woche (`100·(exp(b)−1)`).
- Hinweis in der Doku: Wochenmittel sind schwächer autokorreliert als Tageswerte, bei 12 Punkten ist das Intervall trotzdem nur eine Näherung.

**Tests zuerst** (neue Datei `tests/testthat/test-trends.R`):
1. Lineare Reihe mit bekannter Steigung (z. B. −0,2 bpm/Woche, kleines Rauschen, gesetzter Seed): Steigung innerhalb Toleranz, Urteil `fallend`.
2. Konstante Reihe mit Rauschen: Urteil `kein klarer Trend`.
3. Woche mit weniger als 4 gültigen Tagen entfällt; unvollständige letzte Woche entfällt.
4. Überwiegend annotierte Woche entfällt.
5. Weniger als 6 Wochen: `slope` ist NA, Urteil „zu wenig Daten“.
6. HRV: multiplikative Reihe (+1 % je Woche) ergibt etwa +1 % je Woche.

**Verifikation:** Auf den echten Daten die Werte ausgeben und mit einer unabhängigen Nachrechnung (z. B. Python/`numpy.polyfit` auf denselben Wochenmitteln) vergleichen, wie bei der Gewichtsänderung.

**Anti-Pattern:** keine Kausalaussage („Training wirkt“), nur Trendrichtung; kein Trend aus weniger als 6 Wochen; Tageswerte nicht ohne Wochenaggregation regressieren.

## Phase 4: Dashboard-Karte „Anpassungs-Trends“

**Was zu tun ist**
- `build_dashboard.R`: Wochenreihen und Trendkennzahlen als eigene Konstante (`TRENDS`) in die Nutzlast, analog `WEIGHT_TREND`.
- `dashboard_template.html`: Karte mit drei kleinen Diagrammen (Ruhepuls, HRV, Puls im Schlaf) aus Wochenmitteln, dazu die angepasste Trendgerade, und darunter je Kennwert eine Zeile „−0,3 bpm/Woche [−0,5; −0,1], fallend“. Farbe nur dezent: fallender Ruhepuls und steigende HRV grün, Gegenteil neutral (nicht rot, weil Müdigkeit dasselbe zeigt). Tabelle nach dem Muster der Erholungstabelle (scrollt in der Karte, `.mini-wrap`, `min-width:0`).
- Hinweis: festes Fenster (letzte 12 Wochen), unabhängig vom Zeitraum-Filter; Wochen im Segeltörn fehlen absichtlich; Zusammenhang, keine Ursache; Ruhepuls und HRV ändern sich auch durch Schlaf, Stress, Krankheit und Wärme.

**Verifikation:** Browser (Karte sichtbar, Zahlen entsprechen der Konsole), 375-px-iframe, keine Konsolenfehler; JavaScript-Test nur nötig, wenn Logik im Browser liegt (soll sie nicht: alles in R).

## Phase 5: Abschluss und Verifikation

- `README.md`: Abschnitt Methoden um „Aufbau und Ermüdung“ und „Anpassungs-Trends“ erweitern (inkl. Grenzen), Projektstruktur und Testliste aktualisieren.
- `plans/02-trainingsentwicklung-ergebnis.md`: Status je Phase, Zahlen der echten Daten, offene Punkte (z. B. Feldtest als echter Fortschrittsindikator, optional Garmin Training Status als Verlauf).
- `tests/audit/audit_pmc.R`: Rechnung auf den echten Daten über den Produktionsweg (Annotationen angewendet, wie in `build_dashboard.R`).
- Gesamtlauf: alle Tests (`Rscript tests/testthat.R` unter UTF-8, Python, Node), `build_dashboard.R` zweimal hintereinander (gleiche Ausgabe), Nutzlast-Vergleich gegen `main` (nur neue Spalten/Konstanten dazu).
- Anti-Pattern-Grep: kein `coalesce(load, 0)` auf unbekannte Tage, kein „TSS“ im Code oder Dashboard, keine Zonen-Ampel für Form, keine privaten Daten oder echten Daten im Repository.
- Danach (nur auf Zuruf): Fast-Forward nach `main`, Branch löschen, pushen, Notion-Seiten aktualisieren.

## Offene Punkte nach Plan 02 (Vorschau)
1. Ein echter Fortschrittsindikator braucht einen wiederholten Feldtest (feste Strecke bei festem Puls oder 20-Minuten-Test). Daten dafür lassen sich später in einer eigenen Datei erfassen.
2. Garmin Training Status als reiner Verlauf (bewusst nicht Teil dieses Plans).
3. Die Last von Zeiträumen ohne Aufzeichnung bleibt unbekannt; das Modell friert den Zustand dort ein.
