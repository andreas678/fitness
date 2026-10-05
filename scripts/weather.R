# Wetterdaten (Tagestemperaturen) und ihr Zusammenhang mit Ruhepuls, Schlaf und HRV.
# Quelle: Open-Meteo-Archiv-API (https://open-meteo.com, kostenlos, ohne Schlüssel). Gesendet werden nur
# Koordinaten und Zeitraum, keine persönlichen Daten. Standardort Hamburg; überschreibbar in ~/.Renviron
# (WEATHER_LAT, WEATHER_LON, WEATHER_PLACE). Die jüngsten ein bis zwei Tage liefert die Archiv-API oft noch
# nicht endgültig; deshalb werden die letzten Tage bei jedem Lauf neu geholt.
# Es gilt immer nur das Wetter am Wohnort. In annotierten Zeiträumen (Segeltörn) war der Ort unbekannt,
# diese Tage zählen in der Auswertung nicht.

HEAT_C <- 30   # Hitzetag (DWD): Höchsttemperatur ab 30 °C; build_dashboard.R reicht den Wert als META.heat_c an das Dashboard
WEATHER_DEFAULT <- list(lat = 53.55, lon = 9.99, place = "Hamburg")
WEATHER_VARS <- c("temperature_2m_max", "temperature_2m_min", "temperature_2m_mean")

weather_empty <- function() tibble::tibble(date = as.Date(character()), tmax = numeric(), tmin = numeric(), tmean = numeric())

# data/weather.csv lesen (Pfad F_WEATHER aus helpers.R); ohne Datei eine leere Tabelle
read_weather_cache <- function(path = F_WEATHER) {
  if (!file.exists(path)) return(weather_empty())
  readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(date = readr::col_date(), .default = readr::col_double()))
}

weather_url <- function(lat, lon, start, end) {
  sprintf("https://archive-api.open-meteo.com/v1/archive?latitude=%s&longitude=%s&start_date=%s&end_date=%s&daily=%s&timezone=Europe%%2FBerlin",
          format(lat), format(lon), format(start), format(end), paste(WEATHER_VARS, collapse = ","))
}

# Antwort der API (als Liste) in eine Tabelle; fehlende Werte (null) werden NA
parse_weather <- function(j) {
  d <- j$daily
  if (is.null(d$time) || length(d$time) == 0) return(weather_empty())
  num <- function(x) vapply(as.list(x), function(v) if (is.null(v) || length(v) == 0 || is.na(v)) NA_real_ else as.numeric(v), numeric(1))
  tibble::tibble(date = as.Date(d$time), tmax = num(d$temperature_2m_max), tmin = num(d$temperature_2m_min),
                 tmean = num(d$temperature_2m_mean))
}

# Lädt fehlende Tage nach und speichert sie in `path` (Spalten date, tmax, tmin, tmean). Bei Netzfehlern kein
# Abbruch: Warnung und die vorhandenen Daten bleiben.
update_weather <- function(path = F_WEATHER, lat = WEATHER_DEFAULT$lat, lon = WEATHER_DEFAULT$lon,
                           start, end = Sys.Date(), refetch_days = 7,
                           fetch = function(url) { o <- options(timeout = 30); on.exit(options(o)); jsonlite::fromJSON(url) }) {
  if (!(is.numeric(lat) && length(lat) == 1 && lat >= -90 && lat <= 90)) stop("update_weather: lat muss zwischen -90 und 90 liegen")
  if (!(is.numeric(lon) && length(lon) == 1 && lon >= -180 && lon <= 180)) stop("update_weather: lon muss zwischen -180 und 180 liegen")
  start <- as.Date(start); end <- as.Date(end)
  if (is.na(start) || is.na(end) || start > end) stop("update_weather: start muss vor oder gleich end liegen")
  old <- read_weather_cache(path)
  from <- if (nrow(old) > 0 && min(old$date) <= start) max(start, max(old$date) - refetch_days) else start
  if (from > end) return(old)
  new <- tryCatch(parse_weather(fetch(weather_url(lat, lon, from, end))),
                  error = function(e) { warning("Wetterdaten konnten nicht geladen werden: ", conditionMessage(e), call. = FALSE); NULL })
  if (is.null(new)) return(old)
  out <- dplyr::bind_rows(old[old$date < from, ], new) |> dplyr::distinct(date, .keep_all = TRUE) |> dplyr::arrange(date)
  readr::write_csv(out, path)
  out
}

# Ort aus ~/.Renviron (WEATHER_LAT, WEATHER_LON, WEATHER_PLACE), sonst Hamburg
weather_place <- function() {
  num <- function(nm, default) { v <- suppressWarnings(as.numeric(Sys.getenv(nm))); if (is.na(v)) default else v }
  place <- Sys.getenv("WEATHER_PLACE"); if (!nzchar(place)) place <- WEATHER_DEFAULT$place
  list(lat = num("WEATHER_LAT", WEATHER_DEFAULT$lat), lon = num("WEATHER_LON", WEATHER_DEFAULT$lon), place = place)
}
update_weather_env <- function(start, ...) {
  w <- weather_place()
  update_weather(lat = w$lat, lon = w$lon, start = start, ...)
}

# ---- Zusammenhang Temperatur und Tageswerte -----------------------------------------------------------
# Je Kennwert eine lineare Regression auf die Höchsttemperatur (Mittel aus dem Tag und den zwei Vortagen:
# Hitze wirkt verzögert) mit Newey-West-Konfidenzintervall (Tageswerte sind autokorreliert); Effekt je +5 °C.
# p-Werte nach Holm über die geprüften Kennwerte; das Urteil gilt ab p (Holm) < 0,05. HRV wird logarithmisch gerechnet (Prozent). Nur gültige, vollständige und nicht annotierte Tage.
# Beschreibend: Temperatur hängt mit Jahreszeit, Urlaub und Training zusammen; ein fehlender Zusammenhang
# im Tageswert schließt eine Wirkung in einzelnen Hitzewellen nicht aus.
WEATHER_METRICS <- tibble::tibble(
  col   = c("resting_hr", "sleep_hr", "hrv_night", "sleep_h", "stress_avg"),
  log   = c(FALSE, FALSE, TRUE, FALSE, FALSE),
  unit  = c("bpm je +5 °C", "bpm je +5 °C", "% je +5 °C", "h je +5 °C", "Punkte je +5 °C"))

weather_effects_empty <- function() tibble::tibble(metric = character(), effect = numeric(), lo = numeric(), hi = numeric(),
                                                   n = integer(), effect_unit = character(), p = numeric(), p_holm = numeric(),
                                                   verdict = character())

weather_effects <- function(daily, min_n = 30, nw_lag = 7, today = Sys.Date()) {
  if (!is.data.frame(daily)) stop("weather_effects: daily muss ein data.frame sein")
  if (!all(c("date", "tmax") %in% names(daily))) return(weather_effects_empty())
  d <- clean_daily(daily, today = today)
  d$date <- as.Date(d$date)
  d$t3 <- vapply(seq_len(nrow(d)), function(i) {                  # Mittel von Tag und zwei Vortagen (nur bei 3 Werten)
    v <- d$tmax[match(d$date[i] - 0:2, d$date)]
    if (anyNA(v)) NA_real_ else mean(v)
  }, numeric(1))
  keep <- !d$partial & (if ("ann_note" %in% names(d)) is.na(d$ann_note) else TRUE) & !is.na(d$t3)
  rows <- list()
  for (i in seq_len(nrow(WEATHER_METRICS))) {
    m <- WEATHER_METRICS$col[i]
    if (!m %in% names(d)) next
    y <- d[[m]]
    if (m == "stress_avg") y[!is.na(y) & y < 0] <- NA            # -1 = kein Wert
    if (WEATHER_METRICS$log[i]) y <- ifelse(!is.na(y) & y > 0, log(y), NA_real_)
    ok <- keep & !is.na(y)
    if (sum(ok) < min_n) next
    dd <- data.frame(y = y[ok], t3 = d$t3[ok])
    f <- stats::lm(y ~ t3, dd)
    se <- sqrt(sandwich::NeweyWest(f, lag = nw_lag, prewhite = FALSE, adjust = TRUE)["t3", "t3"])
    tc <- stats::qt(0.975, f$df.residual); b <- 5 * unname(coef(f)["t3"]); lo <- b - tc * 5 * se; hi <- b + tc * 5 * se
    tf <- if (WEATHER_METRICS$log[i]) function(z) 100 * (exp(z) - 1) else identity
    rows[[m]] <- tibble::tibble(metric = m, effect = tf(b), lo = tf(lo), hi = tf(hi), n = as.integer(sum(ok)),
                                effect_unit = WEATHER_METRICS$unit[i], p = 2 * stats::pt(-abs(b / (5 * se)), f$df.residual))
  }
  if (length(rows) == 0) return(weather_effects_empty())
  out <- dplyr::bind_rows(rows)
  out$p_holm <- stats::p.adjust(out$p, "holm")                    # Mehrfachtest über die geprüften Kennwerte
  out$verdict <- ifelse(out$p_holm >= 0.05, "kein klarer Zusammenhang", ifelse(out$effect > 0, "höher bei Hitze", "niedriger bei Hitze"))
  out[c("metric", "effect", "lo", "hi", "n", "effect_unit", "p", "p_holm", "verdict")]
}
