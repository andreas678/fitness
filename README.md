# Fitness-Auswertung aus Garmin Connect

Holt Tages- und Trainingsdaten aus Garmin Connect, bewertet Belastung und Erholung nach gängigen sportwissenschaftlichen Methoden und erzeugt daraus PNG-Grafiken und ein interaktives HTML-Dashboard. Alles läuft lokal; die Daten verlassen den Rechner nicht (außer dem Abruf bei Garmin selbst).

> **Hinweis:** Garmin bietet keine offizielle API für Privatnutzer. Das Projekt nutzt die inoffizielle Python-Bibliothek [`garminconnect`](https://github.com/cyberjunky/python-garminconnect). Sie kann sich ohne Vorwarnung ändern. Die Auswertung ist ein Trainingswerkzeug, kein medizinisches Produkt.

## Was herauskommt

- **`_outputs/fitness_dashboard.html`**: interaktives Dashboard (Kennzahlen, Trainingsbelastung, ACWR, Erholungs-Index, HRV, Schlaf, Gewichtstrend, Herzfrequenzzonen, Aktivitätstabelle).
- **`_outputs/*.png`**: Einzelgrafiken und `fitness_dashboard.png` (Schritte, Ruhepuls, Schlaf, Wochenumfang, Rad-Kilometer, Puls je Aktivität, Body Battery).
- Konsolenausgabe mit Kurzauswertung, Plausibilitätsprüfung und Sensitivitätstabelle.

## Voraussetzungen

- **R** (Pakete): `here`, `dplyr`, `tidyr`, `ggplot2`, `lubridate`, `readr`, `scales`, `tibble`, `jsonlite`, `reticulate`, `patchwork`, `ragg`, `sandwich`. Für die Tests zusätzlich `testthat`.
- **Python 3**: Das virtualenv `r-garmin` mit `garminconnect` legt `garmin_fitness.R` beim ersten Lauf selbst an.
- **Node.js** nur für den JavaScript-Test (optional).
- Für das Dashboard ist Internet nötig: Chart.js wird per CDN geladen.

## Einrichtung

1. R-Pakete installieren:
   ```r
   install.packages(c("here", "dplyr", "tidyr", "ggplot2", "lubridate", "readr", "scales", "tibble",
                      "jsonlite", "reticulate", "patchwork", "ragg", "sandwich", "testthat"))
   ```
2. In `~/.Renviron` eintragen (Datei nach dem Speichern R neu starten):

   | Variable | Bedeutung |
   |---|---|
   | `GARMIN_EMAIL`, `GARMIN_PASSWORD` | Zugang zu Garmin Connect. Nach dem ersten Login liegen Tokens in `~/.garminconnect`, danach wird kein Passwort mehr gebraucht (bei 2-Faktor-Anmeldung fragt das Skript einmal nach dem Code). |
   | `BIRTHDAY` | Geburtsdatum im Format `TT-MM-JJJJ` (für Alter und HFmax-Schätzung; wird nicht ausgegeben). |
   | `GENDER` | `male` oder `female` (Faktor der Belastungsformel). |
   | `HRMAX` | Dein HFmax-Wert. Am besten per Feldtest oder mit Brustgurt ermittelt. Ohne Angabe wird er nach Tanaka geschätzt (208 − 0,7 × Alter, Streuung etwa ±10 bpm). |
   | `RHR_REF` | Optional: feste Ruhepuls-Referenz. Ohne Angabe wird sie einmal berechnet und gespeichert. |

## Benutzung

Aus dem Projektordner:

```bash
Rscript scripts/garmin_fitness.R              # Daten holen (inkrementell) und Grafiken erzeugen
Rscript scripts/build_dashboard.R             # Dashboard aus den gespeicherten Daten bauen
```

Optionen:

| Befehl | Wirkung |
|---|---|
| `garmin_fitness.R --demo` | Testlauf mit synthetischen Daten, nichts wird von Garmin geladen. |
| `garmin_fitness.R --refresh` | Cache ignorieren und alles neu laden (viele API-Aufrufe, dauert). |
| `build_dashboard.R --recalc-profile` | Feste Referenzwerte (Ruhepuls, Pendel-Puls) neu bestimmen. |

Der Abruf lädt nur Neues nach: fehlende Tage, heute und gestern, Tage mit gescheiterten Teilaufrufen sowie fehlende Pulskurven. Ein zweiter Lauf direkt danach holt kaum etwas. `build_dashboard.R` braucht keine Verbindung zu Garmin.

## Datenablage (alles lokal, nicht im Repository)

Der Ordner `data/` ist git-ignoriert, denn er enthält Gesundheits- und Standortdaten.

| Datei | Inhalt |
|---|---|
| `garmin_daily.csv` | Tageswerte (Schritte, Ruhepuls, Schlaf, HRV, Readiness, Body Battery …) mit Erfolgsmarken `fx_*` je Abruf |
| `garmin_activities.csv` | einzelne Aktivitäten |
| `garmin_activity_zones.csv` | Zeit in Herzfrequenzzonen je Aktivität |
| `garmin_activity_hr.csv` | Spitzenpuls je Aktivität (30-Sekunden-Mittel aus der Pulskurve) |
| `garmin_weight.csv` | Wiegungen |
| `profile.json` | feste Referenzwerte (Ruhepuls, Pendel-Puls in bpm) |
| `annotations.csv` | bekannte Zeiträume, optional (siehe unten) |

### Zeiträume beschriften (`data/annotations.csv`)

Für Zeiträume, in denen die Daten einen Sonderfall abbilden, etwa eine mehrtägige Tour ohne Aufzeichnung der Einheiten:

```csv
from,to,note,load_unknown,short_sleep_real
2026-01-10,2026-01-20,"Mehrtagestour, Uhr getragen, kurze Nächte",TRUE,TRUE
```

- `load_unknown`: Uhr getragen, aber Trainingslast nicht erfasst. Die Last bleibt unbekannt, sie wird nicht als 0 gewertet.
- `short_sleep_real`: Kurze Nächte sind echt (z. B. Nachtwachen) und gelten nicht als „Uhr nicht getragen“. Garmin erfasst bei geteiltem Schlaf nur die Hauptphase, die Schlafdauer ist dann eine Untergrenze.

## Methoden in Kürze

- **Belastung (TRIMP):** Banister-Formel aus Dauer und Herzfrequenzreserve. Mit Zeit in Zonen je Zone gerechnet (bildet Intervalle richtig ab), sonst aus dem Durchschnittspuls. Radfahrten ohne Pulsdaten (Pendeln) werden mit einer Intensität angesetzt, die aus den gemessenen Fahrten abgeleitet ist, und sind als „geschätzt“ markiert. Der Anteil geschätzter Last steht im Dashboard.
- **ACWR:** Verhältnis der mittleren Tageslast der letzten 7 zu den letzten 28 Tagen, zusätzlich eine Variante nur mit gemessener Last. Der Bereich 0,8–1,3 ist ein grober Richtwert, kein Schwellenwert für Verletzungsrisiko. Unvollständige Tage zählen nicht mit.
- **Erholungs-Index:** Ruhepuls, Schlaf-Score, Body-Battery-Höchstwert und HRV (auf der ln-Skala) jeweils gegen die eigene 28-Tage-Baseline (z-Wert, niedriger = schlechter). Die vier Signale überlappen (Schlaf-Score und Body Battery r ≈ 0,77), sie entsprechen bei diesen Daten etwa 1,8 unabhängigen Signalen. Der Index ist daher das Mittel der z-Werte geteilt durch seine eigene Standardabweichung; ab −1,5 gilt ein Tag als auffällig (rund 6 % der Tage). Mindestens 3 der 4 Signale müssen vorliegen. Die Einzelsignale bleiben in der Grafik als Hinweistext sichtbar.
- **Erholung nach HIIT:** Regressionsmodell mit dem Wochentag der Messung, Konfidenzintervall mit Newey-West-Standardfehlern, p-Werte nach Holm. Das Dashboard zeigt, auf wie vielen Wochentagen HIIT- und Vergleichstage vorkommen. Ein Zusammenhang, kein Kausalbeweis. Die Training Readiness wird nicht bewertet, weil sie Garmins eigene Last enthält.
- **HFmax-Prüfung:** Vergleich mit dem höchsten 30-Sekunden-Mittel je Einheit. Werte weit über der Tanaka-Schätzung (+ 30 bpm) gelten als Sensorartefakt. HFmax wird nie automatisch angepasst.
- **Gewichtstrend:** lokaler Trend mit 95-%-Band ab 8 Wiegungen. Die Änderung im gewählten Zeitraum (mit Konfidenzintervall) gibt es ab 6 Wiegungen, sonst steht dort „zu wenige für einen Trend“.
- **Datenbereinigung:** Nächte unter 5 h und Ruhepuls unter 45 bpm gelten als Messartefakt (Schwellen in `scripts/helpers.R`).

## Tests

```bash
Rscript tests/testthat.R                                                  # R-Tests
~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python   # Python-Tests
node tests/js/test_weight_change.mjs                                      # JavaScript-Test (Gewichtstrend)
```

`tests/audit/` enthält Skripte aus der Methodenprüfung (Sensitivitäts- und Plausibilitätsrechnungen auf den echten Daten, brauchen `data/`).

## Projektstruktur

```
scripts/
  garmin_fitness.R         Abruf, Cache, Grafiken, Kurzauswertung
  build_dashboard.R        HTML-Dashboard bauen
  dashboard_template.html  Vorlage (Chart.js, Auswertung im Browser)
  helpers.R                gemeinsame Funktionen (Bereinigung, Annotationen, Referenzen, Prüfungen)
  load_recovery.R          Profil, TRIMP, ACWR, Baselines, Erholungsmodell
  garmin_extra.py          Garmin-Abrufe (Schlaf, HRV, Pulskurve, Zonen, Gewicht) mit Wiederholung bei Fehlern
tests/                     R-, Python- und JavaScript-Tests, Audit-Skripte
plans/                     Plan und Ergebnisbericht der Methodenprüfung
data/                      lokale Daten (git-ignoriert)
_outputs/                  erzeugte Grafiken und Dashboard (git-ignoriert)
```

Der Ergebnisbericht der Methodenprüfung mit offenen Punkten steht in [`plans/01-audit-fixes-ergebnis.md`](plans/01-audit-fixes-ergebnis.md).

## Datenschutz

`data/` und `_outputs/` enthalten persönliche Gesundheits- und Standortdaten und sind in `.gitignore` eingetragen. Zugangsdaten stehen in `~/.Renviron` und `~/.garminconnect`, beides außerhalb des Projekts. Vor einem Veröffentlichen des Repositories prüfen, dass keine Datei aus `data/` oder `_outputs/` und keine Zugangsdaten mit committet sind.

## Bekannte Grenzen

- Einzelperson, ein Handgelenk-Sensor: Aussagen gelten für diese Datenbasis und lassen sich nicht verallgemeinern. Optische Pulsmessung am Handgelenk kann bei Intervalltraining Artefakte liefern.
- Der Erholungs-Index ist beschreibend und nicht gegen ein Ergebnis (Krankheit, Leistungsabfall) validiert; Schwelle, Standardabweichung und Korrelation stammen aus dem eigenen Gesamtzeitraum.
- Die Last von Zeiträumen ohne Aufzeichnung bleibt unbekannt und wird nicht geschätzt.
