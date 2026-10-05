# Feature 1: Abruf & Cache

Quelle: Flowchart-Subagent (nur gelesen, nichts ausgeführt). Nicht gelesen: `garmin_fitness.R` 346–369 und 411–555 (zählen zu Feature 6) sowie die Interna der Bibliothek `garminconnect`.

## Ablauf
- Einstieg `Rscript garmin_fitness.R`, Argumente `--refresh` und `--demo` (`garmin_fitness.R:54-56`). Konstanten `DAYS_BACK = 180`, `PLOT_DAYS = 90`, CSV-Pfade `:71-75`.
- Login `garmin_login()` (`:112-151`): virtualenv `r-garmin`, Tokens in `~/.garminconnect`, MFA per `readline`. Bei Fehler: Abbruch, falls ein Cache fehlt, sonst Warnung und Weiterarbeit ohne Abruf (`:382-396`).
- Ablauf mit gültigem Login (`:388-394`): `source_python("garmin_extra.py")`, dann `update_daily`, `update_activities`, `update_weight`, `update_zones`, `update_hr`, `update_weather_env`.
- `update_daily` (`:245-268`) wählt Tage per `days_to_fetch` (`helpers.R:135-147`): fehlende Tage, heute und gestern, Tage mit `fx_* == FALSE`, Altzeilen ohne `fx_*` und ohne Schlafdaten innerhalb von 14 Tagen. „Keine Daten“-Tage werden nicht erneut geholt. Pro Tag `fetch_day` (`:154-194`) plus `extra_day` (`garmin_extra.py:53`), je 0,5 s Pause.
- `_call` (`garmin_extra.py:15-26`) versucht bis zu dreimal (Wartezeit 1 s, dann 2 s) und liefert `(ok, wert)`. So lässt sich „keine Daten“ von „Fehler“ trennen.
- Aktivitäten (`:271-282`) in einem Aufruf über den ganzen Zeitraum, ohne `tryCatch`. Ein API-Fehler bricht das Skript ab.
- Gewicht (`:285-299`), Zonen (`:302-319`) und Puls-Spitzen (`:322-339`): Zonen und Puls je Aktivität einzeln, nur für noch nicht gecachte IDs.
- Wetter (`weather.R:30-57`): Open-Meteo, die letzten 7 Tage werden neu geholt, Netzfehler führen zu einer Warnung und dem alten Cache. `update_weather.R` ist ein eigenständiger Weg ohne Garmin-Login.

## Flowchart
```mermaid
flowchart TD
  A["Rscript garmin_fitness.R<br/>garmin_fitness.R:1"] --> B["Parse args DEMO/REFRESH, constants, paths<br/>garmin_fitness.R:54"]
  B --> C["source helpers.R and weather.R<br/>garmin_fitness.R:107"]
  C --> D{"DEMO?<br/>garmin_fitness.R:378"}
  D -- yes --> DM["demo_data, no fetch or cache<br/>garmin_fitness.R:342"]
  D -- no --> L["garmin_login (virtualenv, tokens, MFA)<br/>garmin_fitness.R:112"]
  L -- error --> LF{"caches exist?<br/>garmin_fitness.R:383"}
  LF -- no --> STOP["stop(e)<br/>garmin_fitness.R:383"]
  LF -- yes --> RC["read_daily_cache + read_act_cache, no fetch<br/>garmin_fitness.R:396"]
  L -- ok --> SP["source_python garmin_extra.py<br/>garmin_fitness.R:388"]
  SP --> UD["update_daily<br/>garmin_fitness.R:245"]
  UD --> DTF["days_to_fetch (missing, today/yesterday, fx FALSE)<br/>helpers.R:135"]
  DTF --> FD["fetch_day per day, sleep 0.5 s<br/>garmin_fitness.R:154"]
  FD --> GS["api get_stats (tryCatch NULL)<br/>garmin_fitness.R:156"]
  FD --> XD["extra_day: sleep, hrv, readiness, training status<br/>garmin_extra.py:53"]
  XD --> CALL["_call, 3 attempts, waits 1 s and 2 s<br/>garmin_extra.py:15"]
  FD --> WD["write_csv garmin_daily.csv<br/>garmin_fitness.R:266"]
  WD --> UA["update_activities<br/>garmin_fitness.R:271"]
  UA --> PFA["py_fetch_activities (get_activities_by_date, id as string)<br/>garmin_fitness.R:199"]
  PFA --> PA["parse_activity<br/>garmin_fitness.R:210"]
  PA --> WA["write_csv garmin_activities.csv<br/>garmin_fitness.R:280"]
  WA --> UW["update_weight<br/>garmin_fitness.R:285"]
  UW --> FW["fetch_weights (get_weigh_ins via _try)<br/>garmin_extra.py:113"]
  FW --> WW["write_csv garmin_weight.csv<br/>garmin_fitness.R:297"]
  WW --> UZ["update_zones<br/>garmin_fitness.R:302"]
  UZ --> FZ["fetch_zones (HR in timezones)<br/>garmin_extra.py:131"]
  FZ --> WZ["write_csv garmin_activity_zones.csv<br/>garmin_fitness.R:317"]
  WZ --> UH["update_hr<br/>garmin_fitness.R:322"]
  UH --> FHP["fetch_hr_peak (get_activity_details)<br/>garmin_extra.py:180"]
  FHP --> PHD["peak_hr_from_details<br/>garmin_extra.py:145"]
  PHD --> WH["write_csv garmin_activity_hr.csv<br/>garmin_fitness.R:337"]
  WH --> UWE["update_weather_env<br/>weather.R:54"]
  UWE --> WP["weather_place (env or Hamburg)<br/>weather.R:49"]
  WP --> UWT["update_weather (7-day refetch, tryCatch to old)<br/>weather.R:30"]
  UWT --> OM["Open-Meteo archive HTTP via fromJSON<br/>weather.R:14"]
  UWT --> WWX["write_csv weather.csv<br/>weather.R:44"]
  WWX --> V["validate_daily/validate_acts + report_validation<br/>garmin_fitness.R:402"]
  RC --> V
  DM --> V
  UWS["Standalone update_weather.R<br/>update_weather.R:4"] --> UWE
```

## Abhängigkeiten zu anderen Features
`days_to_fetch` und `FX_COLS` (`helpers.R:133-147`, Feature 2); `validate_*` (`garmin_fitness.R:402`, Feature 2); `build_dashboard.R` liest alle hier geschriebenen CSVs (Feature 5); `weather_effects` (Feature 4) liest `weather.csv`.

## Schwächen und Auffälligkeiten (nur aus dem Quelltext gelesen)
- Zonen und Puls-Spitzen: Fehlschläge und „keine Daten“ sehen gleich aus (kein Cache-Eintrag). Solche Aktivitäten werden bei jedem Lauf neu abgefragt. Für Tageswerte gibt es dafür `fx_*`-Flags.
- `update_activities` hat kein `tryCatch`. Ein Fehler dort verhindert Gewicht, Zonen und Puls.
- `--refresh` setzt `old` überall auf `NULL` außer beim Wetter. Für Zonen und Puls bedeutet das einen API-Aufruf je Aktivität mit `avg_hr`.
- Randfall ungeprüft: Ohne Cache und ohne neue Aktivitäten könnte `arrange(start)` an einer fehlenden Spalte scheitern.

## Duplikate (Belege)
- 180-Tage-Fenster: `garmin_fitness.R:58` und Standardwert `helpers.R:135`.
- `RIDE_GAP_MIN` und `RIDE_MIN_MIN`: `garmin_fitness.R:61-62`, `build_dashboard.R:25-26`.
- `fx_*`-Namen in drei Stellen, die synchron bleiben müssen: `garmin_extra.py:73`, `garmin_fitness.R:191-192`, `helpers.R:133`.
- `col_types` der Aktivitäten: `garmin_fitness.R:238-241`, `build_dashboard.R:36-38` und `:53-55`. Zonen und Puls: `garmin_fitness.R:304` und `:324`, `build_dashboard.R:46` und `:49`.
- Wetter-CSV-Schema: `weather.R:37` und `build_dashboard.R:32`.
- Tages-CSV mit uneinheitlichen Spaltentypen: `garmin_fitness.R:230-234`, `build_dashboard.R:29`, `update_weather.R:6`.
- `num()`-Hilfsfunktionen: `garmin_fitness.R:97`, `weather.R:23`, `weather.R:50`, `load_recovery.R:122`.

## Konfidenz
Hoch für Kontrollfluss und Zuordnung Funktion → CSV. Die Stichprobe der Zeilenangaben (RIDE_*) stimmt mit dem Quelltext überein.
