# Fitness-Auswertung aus Garmin Connect

Holt Tages- und Trainingsdaten aus Garmin Connect, bewertet Belastung und Erholung nach gängigen sportwissenschaftlichen Methoden und erzeugt daraus ein interaktives HTML-Dashboard. Alles läuft lokal; die Daten verlassen den Rechner nicht (außer dem Abruf bei Garmin selbst).

> **Hinweis:** Garmin bietet keine offizielle API für Privatnutzer. Das Projekt nutzt die inoffizielle Python-Bibliothek [`garminconnect`](https://github.com/cyberjunky/python-garminconnect). Sie kann sich ohne Vorwarnung ändern. Die Auswertung ist ein Trainingswerkzeug, kein medizinisches Produkt.

## Was herauskommt

- **`_outputs/fitness_dashboard.html`**: interaktives Dashboard (Kennzahlen, Trainingsbelastung, ACWR, Aufbau und Ermüdung, Erholungs-Index, Anpassungs-Trends, HRV, Schlaf, Gewichtstrend, Herzfrequenzzonen, Aktivitätstabelle).
  Der Zeitraum lässt sich über die Voreinstellungen (30, 60, 90 Tage, alles) oder frei einstellen: Doppel-Schieberegler und Datumsfelder für Anfang und Ende. Die Vergleichswerte beziehen sich auf den gleich langen Zeitraum davor. Die Anpassungs-Trends (feste 12 Wochen) und die Erholung nach HIIT (gesamte Datenbasis) sind vom Zeitraum unabhängig.
- Konsolenausgabe von `build_dashboard.R` mit Plausibilitätsprüfung und Sensitivitätstabelle.

## Voraussetzungen

- **R** (Pakete): `here`, `dplyr`, `lubridate`, `readr`, `tibble`, `jsonlite`, `reticulate`, `sandwich`. Für die Tests zusätzlich `testthat`.
- **Python 3**: Das virtualenv `r-garmin` mit `garminconnect` legt `garmin_fitness.R` beim ersten Lauf selbst an.
- **Node.js** nur für den JavaScript-Test (optional).
- Für das Dashboard ist Internet nötig: Chart.js wird per CDN geladen.

## Einrichtung

1. R-Pakete installieren:
   ```r
   install.packages(c("here", "dplyr", "lubridate", "readr", "tibble",
                      "jsonlite", "reticulate", "sandwich", "testthat"))
   ```
2. In `~/.Renviron` eintragen (Datei nach dem Speichern R neu starten):

   | Variable | Bedeutung |
   |---|---|
   | `GARMIN_EMAIL`, `GARMIN_PASSWORD` | Zugang zu Garmin Connect. Nach dem ersten Login liegen Tokens in `~/.garminconnect`, danach wird kein Passwort mehr gebraucht (bei 2-Faktor-Anmeldung fragt das Skript einmal nach dem Code). |
   | `BIRTHDAY` | Geburtsdatum im Format `TT-MM-JJJJ` (für Alter und HFmax-Schätzung; wird nicht ausgegeben). |
   | `GENDER` | `male` oder `female` (Koeffizienten der Belastungsformel: Männer 0,64·e^(1,92·x), Frauen 0,86·e^(1,67·x)). Ohne Angabe gilt „male“ mit einer Warnung. |
   | `HRMAX` | Dein HFmax-Wert. Am besten per Feldtest oder mit Brustgurt ermittelt. Ohne Angabe wird er nach Tanaka geschätzt (208 − 0,7 × Alter, Streuung etwa ±10 bpm). |
   | `RHR_REF` | Optional: feste Ruhepuls-Referenz. Ohne Angabe wird sie einmal berechnet und gespeichert. |
   | `WEATHER_LAT`, `WEATHER_LON`, `WEATHER_PLACE` | Optional: Ort für die Tagestemperaturen. Ohne Angabe Hamburg (53,55 / 9,99). |

## Benutzung

Aus dem Projektordner:

```bash
Rscript scripts/garmin_fitness.R              # Daten holen (inkrementell) und lokal speichern
Rscript scripts/build_dashboard.R             # Dashboard aus den gespeicherten Daten bauen
Rscript scripts/update_weather.R              # Tagestemperaturen nachladen (Open-Meteo, braucht Internet; garmin_fitness.R macht das ebenfalls)
```

Optionen:

| Befehl | Wirkung |
|---|---|
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
| `garmin_activity_hr.csv` | Spitzenpuls je Aktivität (30-Sekunden-Mittel aus der Pulskurve). Der Handgelenk-Sensor überschätzt Spitzen: Die HFmax-Prüfung im Dashboard wertet nur Einheiten mit Brustgurt (`HR_STRAP_FROM` und `HR_STRAP_TYPES` in `scripts/helpers.R`) |
| `garmin_weight.csv` | Wiegungen |
| `weather.csv` | Tagestemperaturen (Höchst-, Tiefst-, Mittelwert) am Wohnort aus Open-Meteo |
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
- **Aufbau und Ermüdung:** Banister-Modell auf der Trainingslast (TRIMP): „Fitness“ ist das exponentiell gewichtete Mittel der Tageslast mit 42 Tagen Zeitkonstante, „Ermüdung“ dasselbe mit 7 Tagen, Form ist Fitness minus Ermüdung vom Vortag. Das misst aufgebaute Trainingslast, keine gemessene Leistung, und die Werte sind nicht mit TSS-Werten anderer Programme vergleichbar (deshalb keine Bereichsgrenzen). Tage mit unbekannter Last (Segeltörn, Uhr nicht getragen, heutiger Tag) frieren den Zustand ein und sind in der Grafik gestrichelt; der Hinweis im Dashboard nennt die Spannweite der Fitness, je nachdem, ob unbekannte Tage eingefroren, mit dem Median aufgefüllt oder als 0 gewertet werden. Start beim Mittel der ersten 14 Tage, die ersten 42 Tage gelten als Einschwingphase.
- **Anpassungs-Trends:** Wochenmittel von Ruhepuls, HRV (ln) und Puls im Schlaf über die letzten 12 vollständigen Wochen mit linearer Trendgeraden und 95-%-Konfidenzintervall. Daneben steht dieselbe Steigung über alle vollständigen Wochen. Weichen die beiden Urteile ab (z. B. weil das Fenster in einem Tief beginnt), steht „hängt vom Fenster ab“, und das Urteil gilt nicht als Befund. Eine Woche zählt ab 4 gültigen Tagen; annotierte Wochen (ab 50 % der Tage) und unvollständige Wochen fehlen, unter 6 Wochen gibt es keinen Trend. Ein Zusammenhang, keine Ursache: Die Werte ändern sich auch durch Schlaf, Stress, Wärme und Krankheit.
- **Temperatur:** (Karte im Dashboard standardmäßig ausgeblendet; per Checkbox „Temperatur einblenden“ im Kopf zuschaltbar, die Wahl merkt sich der Browser) Tageshöchsttemperatur am Wohnort (Standard Hamburg, Quelle Open-Meteo; gesendet werden nur Koordinaten und Zeitraum) als Balken neben dem Ruhepuls; Hitzetage ab 30 °C sind markiert. Die Tabelle schätzt je Kennwert (Ruhepuls, Puls im Schlaf, HRV, Schlafdauer, Stress) den Zusammenhang mit der Höchsttemperatur von Tag und zwei Vortagen: lineare Regression, Newey-West-Intervall, p nach Holm über die fünf Kennwerte, Effekt je +5 °C. Annotierte Zeiträume (Segeltörn) zählen nicht, weil der Ort dort nicht der Wohnort war. Beschreibend: Temperatur hängt mit Jahreszeit, Urlaub und Training zusammen, und ein fehlender Tageswert-Zusammenhang schließt eine Wirkung einzelner Hitzewellen nicht aus.
- **Erholung nach HIIT:** Regressionsmodell mit dem Wochentag der Messung, Konfidenzintervall mit Newey-West-Standardfehlern, p-Werte nach Holm. Tage mit unbekannter Last und Zeilen, deren Messtag (Folgetag) annotiert ist (z. B. Segeltörn), zählen nicht. Das Dashboard zeigt, auf wie vielen Wochentagen HIIT- und Vergleichstage vorkommen. Ein Zusammenhang, kein Kausalbeweis. Die Training Readiness wird nicht bewertet, weil sie Garmins eigene Last enthält.
- **HFmax-Prüfung:** Vergleich mit dem höchsten 30-Sekunden-Mittel je Einheit. Werte weit über der Tanaka-Schätzung (+ 30 bpm) gelten als Sensorartefakt. HFmax wird nie automatisch angepasst.
- **Gewichtstrend:** lokaler Trend mit 95-%-Band ab 8 Wiegungen. Die Änderung im gewählten Zeitraum (mit Konfidenzintervall) gibt es ab 6 Wiegungen, sonst steht dort „zu wenige für einen Trend“.
- **Datenbereinigung:** Nächte unter 5 h und Ruhepuls unter 45 bpm gelten als Messartefakt (Schwellen in `scripts/helpers.R`).

## Tests

```bash
Rscript tests/testthat.R                                                  # R-Tests
~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python   # Python-Tests
node tests/js/test_weight_change.mjs                                      # JavaScript-Test (Gewichtstrend)
node tests/js/test_date_range.mjs                                         # JavaScript-Test (Zeitraum-Auswahl)
node tests/js/test_meta_constants.mjs                                    # JavaScript-Test (Template ohne eigene Konstanten-Literale)
node tests/js/test_roll_mean.mjs                                         # JavaScript-Test (Rollmittel über Kalendertage, gleiche Fälle wie roll_apply in R: tests/fixtures/rolling.json)
```

`tests/audit/` enthält Skripte aus der Methodenprüfung und der Trainingsentwicklung (Sensitivitäts- und Plausibilitätsrechnungen auf den echten Daten über den Produktionsweg, brauchen `data/`).

## Projektstruktur

```
scripts/
  garmin_fitness.R         Abruf, Cache, Plausibilitätsprüfung
  build_dashboard.R        HTML-Dashboard bauen
  dashboard_template.html  Vorlage (Chart.js, Auswertung im Browser)
  helpers.R                gemeinsame Funktionen und Konstanten fürs Dashboard, CSV-Leser (Pfade und Spaltentypen), Bereinigung, Annotationen, Referenzen, Prüfungen, Gewichts- und Anpassungstrends
  load_recovery.R          Profil, TRIMP, ACWR, Fitness/Ermüdung, Baselines, Erholungs-Index, Erholungsmodell
  weather.R                Tagestemperaturen (Abruf, Cache) und Zusammenhang mit den Tageswerten
  update_weather.R         Tagestemperaturen allein nachladen
  garmin_extra.py          Garmin-Abrufe (Schlaf, HRV, Pulskurve, Zonen, Gewicht) mit Wiederholung bei Fehlern
tests/                     R-, Python- und JavaScript-Tests, Audit-Skripte
plans/                     Pläne und Ergebnisberichte (Methodenprüfung, Trainingsentwicklung)
data/                      lokale Daten (git-ignoriert)
_outputs/                  erzeugtes Dashboard (git-ignoriert)
```

Die Ergebnisberichte mit offenen Punkten stehen in [`plans/01-audit-fixes-ergebnis.md`](plans/01-audit-fixes-ergebnis.md) und [`plans/02-trainingsentwicklung-ergebnis.md`](plans/02-trainingsentwicklung-ergebnis.md).

## Datenschutz

`data/` und `_outputs/` enthalten persönliche Gesundheits- und Standortdaten und sind in `.gitignore` eingetragen. Zugangsdaten stehen in `~/.Renviron` und `~/.garminconnect`, beides außerhalb des Projekts. Vor einem Veröffentlichen des Repositories prüfen, dass keine Datei aus `data/` oder `_outputs/` und keine Zugangsdaten mit committet sind.

## Bekannte Grenzen

- Einzelperson, ein Handgelenk-Sensor: Aussagen gelten für diese Datenbasis und lassen sich nicht verallgemeinern. Optische Pulsmessung am Handgelenk kann bei Intervalltraining Artefakte liefern.
- Der Erholungs-Index ist beschreibend und nicht gegen ein Ergebnis (Krankheit, Leistungsabfall) validiert; Schwelle, Standardabweichung und Korrelation stammen aus dem eigenen Gesamtzeitraum.
- Die Last von Zeiträumen ohne Aufzeichnung bleibt unbekannt und wird nicht geschätzt; die Fitness-Kurve ist dort eingefroren.
- Es gibt keinen einzelnen Erfolgs-KPI: VO₂max liefert zu wenige Werte, Leistungsdaten fehlen. Ein echter Fortschrittsindikator bräuchte einen wiederholten Feldtest.
