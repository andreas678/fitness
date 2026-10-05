# Ergebnis: Trainingsentwicklung (Plan 02, Stand 2026-10-05)

Ausgangsfrage: Gibt es einen Index, der den Trainingserfolg als KPI misst? Antwort der Prüfung: Ein einzelner Erfolgs-KPI ist mit diesen Daten nicht seriös (VO₂max konstant 45,2 und nur an 30 Tagen vorhanden, nur 6 Radfahrten mit Puls über 20 min, keine Leistungsmessung). Umgesetzt wurden deshalb zwei belegbare Bausteine.

## Status je Phase

| Phase | Inhalt | Status | Beleg |
|-------|--------|--------|-------|
| 1 | Fitness-Ermüdungs-Modell in R (`fitness_fatigue`, `pmc_sensitivity`) | fertig | 36 Prüfungen: Konvergenz, Sprungantwort (1 − e⁻¹ nach τ Tagen), Form aus Vortagswerten, Einfrieren, Start, Eingabeprüfung |
| 2 | Dashboard-Karte „Aufbau und Ermüdung“ | fertig | Zwei Diagramme, KPI „Form“, Hinweis mit Spannweite; Nutzlast gegen `main` unverändert bis auf 5 neue Spalten |
| 3 | Anpassungs-Trends in R (`adaptation_trends`) | fertig | 32 Prüfungen; Ruhepuls-Trend stimmt mit unabhängiger numpy-Rechnung überein (Steigung 0,255, KI [0,131; 0,379], Wochenmittel exakt gleich) |
| 4 | Dashboard-Karte „Anpassungs-Trends“ | fertig | Drei Wochen-Diagramme, Tabelle mit KI und Urteil, Hinweis; 375-px-iframe ohne horizontales Scrollen |
| 5 | Abschluss | fertig | siehe Verifikation |

## Ergebnisse auf den echten Daten (über den Produktionsweg, Stand 2026-10-05)

**Aufbau und Ermüdung:** Fitness 39,7, Ermüdung 40,2, Form −0,5. 32 von 182 Tagen sind eingefroren (die 29 Segeltörn-Tage und drei weitere), 42 gehören zur Einschwingphase. Die Behandlung unbekannter Tage verschiebt die aktuelle Fitness zwischen 29,5 (Tage als 0 gewertet) und 39,7 (eingefroren); das Dashboard weist diese Spannweite aus. 47 % der Last im 90-Tage-Fenster sind geschätzt.

**Anpassungs-Trends** (8 von 12 Wochen gültig, der Segeltörn fehlt):

| Kennwert | Steigung je Woche | 95-%-Intervall | Urteil |
|---|---|---|---|
| Ruhepuls | +0,26 bpm | [+0,13; +0,38] | steigend (ungünstig) |
| HRV nachts | −0,8 % | [−2,0; +0,5] | kein klarer Trend |
| Puls im Schlaf | +0,15 bpm | [−0,03; +0,33] | kein klarer Trend |

Der Ruhepuls liegt von 52,2 bpm (KW 28) auf 55,3 bpm (KW 39). Der Sprung liegt über die Lücke des Segeltörns. Ursache ungeklärt: Pause, Wärme, Schlaf, Stress oder Krankheit sind möglich. Der Trend ist ein Zusammenhang, keine Ursache.

## Verifikation
- **Tests:** R 274 Prüfungen (davon neu 68 für Fitness/Ermüdung und Trends, 12 davon Eingabeprüfungen), Python 13, JavaScript 7. Alle grün.
- **Reproduzierbar:** Zwei Builds hintereinander liefern dieselbe Seite (ohne Zeitstempel).
- **Nutzlast gegen `main`:** ACTS, WEIGHT, WEIGHT_TREND und RECOVERY identisch; in DAILY nur die neuen Spalten `ctl`, `atl`, `tsb`, `pmc_gap`, `pmc_warmup`; neue Konstante `TRENDS`. Keine bestehende Spalte verändert.
- **Anti-Pattern-Grep:** Kein `coalesce(load, …)` auf unbekannte Tage; „TSS“ steht nur im Hinweis, dass die Werte nicht vergleichbar sind; keine absoluten Zonen oder Ampel für die Form; keine Kausalsprache.
- **Datenschutz:** Keine Datei aus `data/` oder `_outputs/` im Repository; Audit-Skripte lesen `data/` nur lokal.
- **Audit-Skripte:** `tests/audit/audit_pmc.R`, `tests/audit/audit_trends.R` (beide über den Produktionsweg mit angewendeten Annotationen und festen Referenzwerten).

## Was noch offen ist
1. **Echter Fortschrittsindikator:** braucht einen wiederholten Feldtest (feste Strecke bei festem Puls oder 20-Minuten-Test) und eine Datei für die Ergebnisse.
2. **Garmin Training Status** als reiner Verlauf (bewusst nicht Teil dieses Plans).
3. **Last unbekannter Zeiträume** bleibt unbekannt; die Fitness-Kurve ist dort eingefroren.
4. **Schwelle und Trendfenster** (42/7 Tage, 12 Wochen, 4 gültige Tage) sind Konventionen, nicht an einem Ergebnis geprüft.
5. **Beobachtung:** Ruhepuls-Anstieg weiter verfolgen; bei Fortsetzung Ursachen prüfen (Wärme, Schlaf, Krankheit).
