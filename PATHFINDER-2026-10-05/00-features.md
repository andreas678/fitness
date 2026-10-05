# Feature-Inventar (Pathfinder, 2026-10-05)

Grundlage: Explore-Durchsicht vom 2026-10-05 (Stand `main` @ `747898f`). Die Zeilenangaben stammen aus dieser Durchsicht. Phase 1 prüft sie gegen den Quelltext.

| # | Feature | Einstiegspunkte | Kerndateien | Zweck |
|---|---|---|---|---|
| 1 | Abruf & Cache | `garmin_fitness.R:112` (Login), `:245` `update_daily`, `:271` `update_activities`, `:285` `update_weight`, `:302` `update_zones`, `:322` `update_hr`; `weather.R:30` `update_weather`; `update_weather.R` | `scripts/garmin_fitness.R` (Zeilen 1–340), `scripts/garmin_extra.py`, `scripts/weather.R` (Abruf), `scripts/update_weather.R`, `helpers.R:135` `days_to_fetch` | Garmin- und Open-Meteo-Daten inkrementell holen und als CSV cachen |
| 2 | Bereinigung, Annotationen & Validierung | `helpers.R:71-92` `flag_daily`/`clean_daily`, `:101-127` Annotationen, `:156-187` Validierung, `:25` `merge_rides`, `:193-207` frozen profile | `scripts/helpers.R` (ohne `weight_trend`, `adaptation_trends`) | Rohdaten bereinigen, Artefakte maskieren, Zeiträume annotieren, Plausibilität melden |
| 3 | Belastung & Erholung | `load_recovery.R:15` `athlete_profile`, `:65-155` TRIMP/Zonen/Pendel, `:190` `fitness_fatigue`, `:224` `daily_load_recovery`, `:316` `recovery_index` | `scripts/load_recovery.R` (ohne HIIT-Modell) | TRIMP, ACWR, Banister-PMC, Baselines, z-Werte, Erholungs-Index |
| 4 | Inferenz-Module | `load_recovery.R:358` `recovery_model`, `weather.R:74` `weather_effects`, `helpers.R:273` `adaptation_trends`, `helpers.R:215` `weight_trend` | die genannten Funktionen | Regressionen mit robusten Intervallen: HIIT-Erholung, Temperatur, Wochentrends, Gewicht |
| 5 | Dashboard-Build & Frontend | `build_dashboard.R` (ganze Datei), `dashboard_template.html` (`renderKPIs` `:287`, `setupRange` `:717`, `renderWeather` `:550`, `renderRecovery` `:592`) | `scripts/build_dashboard.R`, `scripts/dashboard_template.html` | Daten zusammenführen, als JSON einspeisen, interaktives statisches HTML erzeugen |
| 6 | Legacy-PNG-Plots & Konsolenbericht | `garmin_fitness.R:429-522` Plots 6.1–6.7, `:545` Zusammenfassung, `:342` `--demo` | `scripts/garmin_fitness.R` (Zeilen 342–555) | Statische PNG-Plots und 30-Tage-Konsolenzusammenfassung; Verdacht auf Doppelung mit dem Dashboard |

## Grenzfälle
- `garmin_fitness.R` gehört zu drei Features (Abruf 1–340, Demo 342, Plots 429–555). Die Grenze ist die Zeilenzahl.
- `helpers.R` enthält Bereinigung (Feature 2) und Statistik (Feature 4). Die Mischung ist ein Duplikat-/Strukturkandidat.
- `weather.R` enthält Abruf (Feature 1) und `weather_effects` (Feature 4).
- `recovery_model` steht in `load_recovery.R` (Zeilen 337–401), zählt aber zu Feature 4.
- Tests (`tests/`) sind kein eigenes Feature. Sie dienen als Beleg für das erwartete Verhalten.

## Außerhalb des Umfangs
`data/`, `_outputs/`, `.RData`, `plans/` und `tests/audit/` (Skripte, die echte Daten brauchen) werden nicht kartiert.
