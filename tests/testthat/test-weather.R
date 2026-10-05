source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "weather.R"))

api <- function(dates, tmax = 20, tmin = 10, tmean = 15) {          # Antwort der Open-Meteo-Archiv-API (Ausschnitt)
  n <- length(dates)
  list(daily = list(time = format(dates), temperature_2m_max = rep(tmax, length.out = n),
                    temperature_2m_min = rep(tmin, length.out = n), temperature_2m_mean = rep(tmean, length.out = n)))
}

test_that("parse_weather macht aus der API-Antwort eine Tabelle, fehlende Werte werden NA", {
  j <- api(as.Date("2026-06-01") + 0:2); j$daily$temperature_2m_max <- list(25.1, NULL, 27)
  w <- parse_weather(j)
  expect_equal(names(w), c("date", "tmax", "tmin", "tmean"))
  expect_equal(w$date, as.Date("2026-06-01") + 0:2)
  expect_equal(w$tmax, c(25.1, NA, 27)); expect_equal(w$tmin, rep(10, 3))
  expect_equal(nrow(parse_weather(list())), 0)
})

test_that("weather_url enthält Ort, Zeitraum und Zeitzone", {
  u <- weather_url(53.55, 9.99, as.Date("2026-04-01"), as.Date("2026-10-05"))
  expect_match(u, "latitude=53.55"); expect_match(u, "longitude=9.99")
  expect_match(u, "start_date=2026-04-01"); expect_match(u, "end_date=2026-10-05")
  expect_match(u, "temperature_2m_max"); expect_match(u, "Europe%2FBerlin")
})

test_that("update_weather lädt ohne Datei den ganzen Zeitraum und schreibt die Datei", {
  f <- tempfile(fileext = ".csv"); calls <- list()
  fetch <- function(url) { calls[[length(calls) + 1]] <<- url; api(as.Date("2026-06-01") + 0:9) }
  w <- update_weather(f, start = as.Date("2026-06-01"), end = as.Date("2026-06-10"), fetch = fetch)
  expect_equal(length(calls), 1); expect_match(calls[[1]], "start_date=2026-06-01")
  expect_equal(nrow(w), 10); expect_true(file.exists(f))
  expect_equal(nrow(readr::read_csv(f, show_col_types = FALSE)), 10)
})

test_that("update_weather holt nur die letzten Tage nach und ersetzt überlappende Werte", {
  f <- tempfile(fileext = ".csv")
  update_weather(f, start = as.Date("2026-06-01"), end = as.Date("2026-06-20"),
                 fetch = function(u) api(as.Date("2026-06-01") + 0:19, tmax = 20))
  calls <- character()
  w <- update_weather(f, start = as.Date("2026-06-01"), end = as.Date("2026-06-25"), refetch_days = 7,
                      fetch = function(u) { calls <<- c(calls, u); api(as.Date("2026-06-13") + 0:12, tmax = 30) })
  expect_match(calls, "start_date=2026-06-13")                       # 20.06. minus 7 Tage
  expect_equal(nrow(w), 25)
  expect_equal(w$tmax[w$date == as.Date("2026-06-12")], 20)          # alt, nicht neu geladen
  expect_equal(w$tmax[w$date == as.Date("2026-06-25")], 30)          # neu
  expect_equal(w$tmax[w$date == as.Date("2026-06-15")], 30)          # überlappend: neuer Wert gilt
})

test_that("update_weather bricht bei Netzfehlern nicht ab und behält die vorhandenen Daten", {
  f <- tempfile(fileext = ".csv")
  update_weather(f, start = as.Date("2026-06-01"), end = as.Date("2026-06-05"), fetch = function(u) api(as.Date("2026-06-01") + 0:4))
  expect_warning(w <- update_weather(f, start = as.Date("2026-06-01"), end = as.Date("2026-06-09"), fetch = function(u) stop("kein Netz")), "Wetterdaten")
  expect_equal(nrow(w), 5)
  expect_warning(e <- update_weather(tempfile(fileext = ".csv"), start = as.Date("2026-06-01"), end = as.Date("2026-06-09"), fetch = function(u) stop("kein Netz")), "Wetterdaten")
  expect_equal(nrow(e), 0)
})

test_that("update_weather prüft die Eingaben", {
  d0 <- as.Date("2026-06-01")
  expect_error(update_weather(tempfile(), lat = 95, lon = 9, start = d0, end = d0 + 1, fetch = identity), "lat")
  expect_error(update_weather(tempfile(), lat = 53, lon = 200, start = d0, end = d0 + 1, fetch = identity), "lon")
  expect_error(update_weather(tempfile(), start = d0 + 5, end = d0, fetch = identity), "start")
})

# ---- Zusammenhang Temperatur und Tageswerte ----------------------------------------------------------
mk_wx <- function(n = 240, effect = 0, seed = 1, ann = FALSE) {
  set.seed(seed)
  date <- as.Date("2026-04-01") + 0:(n - 1)
  tmax <- 18 + 8 * sin(seq_len(n) / 25) + rnorm(n, 0, 3)
  t3 <- stats::filter(tmax, rep(1 / 3, 3), sides = 1)
  rhr <- 54 + effect * as.numeric(ifelse(is.na(t3), mean(tmax), t3)) / 5 + rnorm(n, 0, 1)
  d <- tibble(date = date, steps = 8000, sleep_h = 7, resting_hr = rhr, sleep_hr = 59 + rnorm(n), hrv_night = 35 * exp(rnorm(n, 0, 0.1)),
              stress_avg = 28 + rnorm(n), tmax = tmax)
  if (ann) { d$ann_note <- NA_character_; d$ann_note[40:70] <- "Törn"; d$resting_hr[40:70] <- 99 }
  d
}
TODAY <- as.Date("2026-12-31")

test_that("weather_effects findet einen bekannten Zusammenhang je +5 °C", {
  r <- weather_effects(mk_wx(effect = 1.0), today = TODAY); r <- r[r$metric == "resting_hr", ]
  expect_equal(r$effect, 1.0, tolerance = 0.3); expect_true(r$lo < 1 && 1 < r$hi)
  expect_equal(r$verdict, "höher bei Hitze"); expect_equal(r$effect_unit, "bpm je +5 °C")
})

test_that("weather_effects meldet ohne Zusammenhang kein klares Ergebnis", {
  r <- weather_effects(mk_wx(effect = 0, seed = 5), today = TODAY); r <- r[r$metric == "resting_hr", ]
  expect_true(r$lo < 0 && 0 < r$hi); expect_equal(r$verdict, "kein klarer Zusammenhang")
})

test_that("weather_effects schließt annotierte Zeiträume aus (Ort unbekannt)", {
  r <- weather_effects(mk_wx(effect = 0, seed = 5, ann = TRUE), today = TODAY); r <- r[r$metric == "resting_hr", ]
  expect_lt(abs(r$effect), 1)                                       # die 99er-Werte im annotierten Zeitraum zählen nicht
  expect_equal(r$n, 240 - 31 - 2)                                   # 31 annotierte Tage, 2 Tage ohne 3-Tage-Mittel
})

test_that("weather_effects: HRV in Prozent, fehlende Spalten und zu wenige Daten ohne Absturz", {
  r <- weather_effects(mk_wx(), today = TODAY)
  expect_equal(r$effect_unit[r$metric == "hrv_night"], "% je +5 °C")
  expect_equal(nrow(weather_effects(mk_wx()[, c("date", "steps", "tmax")], today = TODAY)), 0)
  expect_equal(nrow(weather_effects(mk_wx(n = 20), today = TODAY)), 0)
  expect_equal(nrow(weather_effects(mk_wx() |> dplyr::select(-tmax), today = TODAY)), 0)
})

test_that("weather_effects korrigiert die p-Werte nach Holm und urteilt auf dieser Basis", {
  r <- weather_effects(mk_wx(effect = 1.0), today = TODAY)
  expect_true(all(c("p", "p_holm") %in% names(r)))
  expect_true(all(r$p_holm >= r$p - 1e-12)); expect_true(all(r$p_holm <= 1))
  expect_equal(r$p_holm, stats::p.adjust(r$p, "holm"))
  expect_equal(r$verdict == "höher bei Hitze", r$p_holm < 0.05 & r$effect > 0)
  # ein Rand-Effekt, der unkorrigiert knapp signifikant wäre, wird mit Holm nicht mehr als Befund gewertet
  d <- mk_wx(effect = 0, seed = 5); r0 <- weather_effects(d, today = TODAY)
  expect_true(all(r0$verdict[r0$p_holm >= 0.05] == "kein klarer Zusammenhang"))
})

test_that("read_weather_cache liefert ohne Datei eine leere Tabelle und liest sonst Datum und Zahlen", {
  nf <- file.path(tempdir(), "weather-gibt-es-nicht.csv")
  e <- read_weather_cache(nf)
  expect_equal(nrow(e), 0); expect_equal(names(e), c("date", "tmax", "tmin", "tmean"))
  f <- tempfile(fileext = ".csv")
  readr::write_csv(tibble::tibble(date = as.Date("2026-07-01") + 0:1, tmax = c(31.2, 24), tmin = c(18, 15), tmean = c(24, 19)), f)
  w <- read_weather_cache(f)
  expect_s3_class(w$date, "Date"); expect_equal(w$tmax, c(31.2, 24))
  expect_equal(F_WEATHER, file.path(DIR_DATA, "weather.csv"))
})
