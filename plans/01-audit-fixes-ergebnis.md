# Ergebnis: Befunde aus der Methodenprüfung (Plan 01, Stand 2026-10-05)

Status je Befund der Prüfung. „Behoben“ heißt: Ursache beseitigt und durch einen Test oder eine Nachrechnung belegt. „Abgemildert“ heißt: besser, aber mit einer Restunsicherheit, die im Dashboard ausgewiesen wird. „Offen“ heißt: nicht bearbeitet.

## A. Befunde, die Schlussfolgerungen verfälschten

| # | Befund | Status | Phase | Beleg |
|---|--------|--------|-------|-------|
| A1 | HIIT-Erholung: Wochentag-Konfundierung, Autokorrelation, keine Mehrfachtest-Korrektur, Readiness zirkulär | behoben, Design-Grenze bleibt | 4 | Modell mit Wochentag, Newey-West-KI, Holm; Simulation (300 Läufe): Fehlalarmrate 5,3 %, KI-Deckung 90 %; roher Vergleich schätzt −1,3 statt −5. Nur 2 von 7 Wochentagen haben beide Gruppen (Dashboard weist das aus). |
| A2 | HFmax nicht belastbar, 15 von 102 Einheiten darüber | abgemildert | 5 | Prüfung gegen 30-s-Spitze aus der Pulskurve (101 von 102 Einheiten), Plausibilitätsgrenze Tanaka + 30 bpm, Beschriftung „eingestellt via HRMAX“. Offen: kein Feldtest; Garmin rechnet intern weiter mit 178 bpm. |
| A3 | 28 % der Last angenommen (konstante Pendel-HFR 0,40) | abgemildert | 3 | Pendel-Puls aus den 6 gemessenen Fahrten abgeleitet (113 bpm, Spannweite 86–130), ACWR-Variante nur mit gemessener Last, Anteil geschätzter Last im Dashboard, Sensitivitätstabelle. Die Last bleibt zu 34 % (90 Tage: 47 %) geschätzt. |
| A4 | „Uhr nicht getragen“ nur über fehlende Aktivitäten erkannt | behoben | 3 | Wear-Erkennung über Schritte, Annotationsdatei für den Segeltörn (29 Tage „Last unbekannt“). Alle 12 früher ausgeblendeten Nächte unter 5 h lagen in diesem Zeitraum und waren echte Nachtwachen. |
| A5 | `merge_rides` stürzt bei mehrsegmentigen Fahrten mit Puls ab | behoben | 1 | Roter → grüner Test; Zonen gemergter Fahrten werden über alle Segmente summiert. |
| A6 | Unvollständige Tage in Mittelwerten und ACWR | behoben | 2 | Flag `partial`; ACWR aktuell 0,81 → 1,02 (der heutige Tag ging mit Last 0 ein). |

## B. Methodische Schwächen

| # | Befund | Status | Phase | Beleg / Hinweis |
|---|--------|--------|-------|-----------------|
| B7 | Schlaf-/Ruhepuls-Filter hartkodiert und inkonsistent (HTML gegen R) | behoben | 2, 3 | Eine Quelle in `helpers.R`, vom Dashboard mitgenutzt. Folge von Phase 3: Der Ø Schlaf im 90-Tage-Fenster sinkt von 7,6 auf 6,8 h, weil die Nachtwachen jetzt zählen (Garmin erfasst bei geteiltem Schlaf nur die Hauptphase, die Dauer ist eine Untergrenze). Abschaltbar über `short_sleep_real` in `data/annotations.csv`. |
| B8 | Warn-Signale redundant (Schlaf–Body Battery r = 0,74), HRV roh statt ln(RMSSD), Schwellen nicht validiert | abgemildert | 9 | Alle vier Signale korrelieren (|r| 0,19–0,77), zusammen entsprechen sie 1,8 unabhängigen; 8 von 27 Tagen mit „≥ 2 Signalen“ gingen allein auf Schlaf-Score plus Body Battery zurück. Ersatz der Zählung „≥ 2 von 4“ durch einen Erholungs-Index (Mittel der z-Werte, auf Streuung 1 skaliert, Schwelle −1,5, ≥ 3 Signale nötig; 9 Tage = 5,8 %, alle davon auch nach der alten Zählung auffällig). HRV-z auf ln-Skala (Schiefe 0,93 → 0,34; Flags auf den echten Daten unverändert). Schwelle bleibt unvalidiert: Es gibt keine Ereignisdaten (Krankheit). Prüfung: `tests/audit/audit_b8.R`. |
| B9 | ACWR: Evidenz des Richtbereichs umstritten | abgemildert | 3 | Methodenwahl (gekoppelt, entkoppelt, EWMA) ändert bei deinen Daten wenig; Garmin-ACWR korreliert nur mit r = 0,53. Hinweis „grober Richtwert“ im Dashboard, zweite Linie mit gemessener Last. |
| B10 | Gewicht: Einzelwert gegen Einzelwert | behoben | 7 | Lokaler Trend mit 95-%-Band, KPI als lineare Änderung mit Konfidenzintervall (−3,62 kg [−4,88; −2,35]), unabhängig in R nachgerechnet; unter 6 Wiegungen kein Trend. |
| B11 | Pipeline: Fehler als NA gecacht, wandernde Referenz, keine Prüfungen, keine Tests | behoben | 1, 6 | `fx_*`-Erfolgsmarken, Retry, Plausibilitätsprüfung, feste Referenz in `data/profile.json`, Testgerüst (R, Python, JavaScript). Restpunkt: Alt-Zeilen ohne Marken bleiben „unbekannt“ (nur `--refresh` holt sie nach). |
| B12 | Ø-Puls-Plot mischt Aktivitätstypen, laufende Woche als Einbruch | behoben | 2, 7 | Trend je Gruppe ab 8 Einheiten (ohne „Sonstiges“), unvollständige Wochen markiert. |

## Zusätzlicher Fund in Phase 8
Das Dashboard scrollte bei 375 px Breite horizontal. Das bestand schon vor allen Änderungen (Inhalt 489 px), die breitere Erholungstabelle aus Phase 4 machte es schlimmer (779 px). Behoben: Tabellen scrollen innerhalb ihrer Karte, Karten dürfen das Raster nicht aufblähen. Nachgemessen in einem 375-px-iframe: Seitenbreite 375 px.

## Verifikation
- Tests: R 190 Prüfungen (annotations, clean, helpers, load, pipeline, profile, recovery, weight), Python 13, JavaScript 7. Alle grün.
- Referenzzahlen der ursprünglichen Prüfung (mit `HRMAX=182`) reproduzieren sich: 286 Einheiten, 101 mit Zonen, 15 von 102 über HFmax (Max 223), 29 Tage ohne Last, TRIMP-Quellen 1/184/101 mit Summen 53/1.794/4.601, TRIMP-Summe 6.449 (und 7.487 / 6.823 / 5.827 bei HFmax 172 / 178 / 190), 27,8 % geschätzte Last.
- Beabsichtigte Abweichungen: ACWR (24 Tage, nur durch die drei unvollständigen Tage), Erholungstabelle, Gewicht-KPI, HFmax-Texte, TRIMP durch HFmax 192 und Pendel-HFR 0,43.
- Gegenüber der Baseline vor allen Phasen ändern sich bei den Rohspalten nur die Werte des heutigen Tages.
- Anti-Pattern-Grep: sauber (siehe Phase-8-Commit).

## Was noch offen ist
1. **B8** (Rest): Schwelle des Erholungs-Index gegen Ereignisse (Krankheit, Leistungseinbruch) prüfen. Dafür müssten solche Zeiträume in `data/annotations.csv` erfasst werden.
2. **HFmax 192**: per Feldtest oder Brustgurt absichern; in Garmin Connect dasselbe eintragen, damit die Garmin-Zonen (derzeit 178) zu deiner Belastungsrechnung passen.
3. **Segeltörn**: Die Last dieser 29 Tage ist unbekannt. Schätzen ließe sie sich höchstens aus dem Tagespuls, das wäre eine neue Annahme.
4. **Pendel-Puls ist festgeschrieben**: bei mehr gemessenen Fahrten einmal `Rscript scripts/build_dashboard.R --recalc-profile`.
5. **Merge**: Die Arbeit liegt auf sieben gestapelten Branches (`phase1-…` bis `phase8-verification`), `main` ist unverändert.

## Bedienung (neu)
- Tests: `Rscript tests/testthat.R`, `~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python`, `node tests/js/test_weight_change.mjs`.
- `data/annotations.csv`: bekannte Zeiträume (von, bis, Notiz, `load_unknown`, `short_sleep_real`).
- `data/profile.json`: feste Referenzwerte; `RHR_REF` in `~/.Renviron` überschreibt den Ruhepuls.
- `Rscript scripts/garmin_fitness.R` lädt Pulskurven (Spitzenpuls) und gescheiterte Tage inkrementell nach.
