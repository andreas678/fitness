source(here::here("scripts", "helpers.R"))

# Testdaten: je Zeile ein Rad-Segment (Spalten wie in garmin_activities.csv)
seg <- function(id, start, dur, hr = NA_real_, km = 1, type = "cycling") {
  tibble(activity_id = id, start = as.POSIXct(start, tz = "UTC"), name = "x", type_key = type,
         distance_km = km, duration_min = dur, avg_hr = hr, max_hr = hr + 20, kcal = 10,
         elev_gain = 1, te_aerobic = NA_real_, te_anaerobic = NA_real_)
}

test_that("merge_rides fasst Segmente zusammen und gewichtet den Puls nach Dauer", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 10, 100),
                    seg("2", "2026-01-01 08:20:00", 30, 140))
  out <- merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)
  expect_equal(nrow(out), 1)
  expect_equal(out$duration_min, 40)
  expect_equal(out$avg_hr, 130)            # (10*100 + 30*140) / 40
  expect_equal(out$distance_km, 2)
  expect_equal(out$segment_ids, "1;2")
})

test_that("merge_rides mittelt den Puls nur über Segmente mit Pulsdaten", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 10, NA),
                    seg("2", "2026-01-01 08:20:00", 30, 140))
  out <- merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)
  expect_equal(out$avg_hr, 140)
  expect_equal(out$duration_min, 40)
})

test_that("merge_rides lässt avg_hr NA, wenn kein Segment Pulsdaten hat", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 10), seg("2", "2026-01-01 08:20:00", 30))
  expect_true(is.na(merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)$avg_hr))
})

test_that("merge_rides trennt Fahrten bei großem Abstand und an Tagesgrenzen", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 10),
                    seg("2", "2026-01-01 09:00:00", 10),   # Abstand 50 min > 30
                    seg("3", "2026-01-02 08:00:00", 10))
  expect_equal(nrow(merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)), 3)
})

test_that("merge_rides verwirft sehr kurze Fahrten", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 2), seg("2", "2026-01-01 12:00:00", 10))
  out <- merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)
  expect_equal(out$activity_id, "2")
})

test_that("merge_rides lässt andere Aktivitäten unverändert und setzt segment_ids", {
  acts <- bind_rows(seg("1", "2026-01-01 08:00:00", 60, 140, type = "hiit"),
                    seg("2", "2026-01-01 17:00:00", 10))
  out <- merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN)
  expect_equal(nrow(out), 2)
  expect_equal(out$segment_ids[out$type_key == "hiit"], "1")
})

test_that("activity_group ordnet Typen den Gruppen zu", {
  expect_equal(activity_group(c("cycling", "hiit", "treadmill_running", "walking", "sailing", "breathwork", NA)),
               c("Rad", "Gym / HIIT", "Laufen", "Gehen / Wandern", "Segeln / Wasser", "Sonstiges", "Sonstiges"))
})

test_that("sum_na und max_na geben NA nur zurück, wenn alles NA ist", {
  expect_true(is.na(sum_na(c(NA_real_, NA_real_))))
  expect_equal(sum_na(c(1, NA, 2)), 3)
  expect_true(is.na(max_na(NA_real_)))
  expect_equal(max_na(c(1, NA, 5)), 5)
})

# ---- Konstanten, die das Dashboard über META bekommt (siehe build_dashboard.R) ----------------
test_that("merge_rides nutzt als Standard die Konstanten RIDE_GAP_MIN und RIDE_MIN_MIN", {
  expect_equal(formals(merge_rides)$gap_min, quote(RIDE_GAP_MIN))
  expect_equal(formals(merge_rides)$min_min, quote(RIDE_MIN_MIN))
})

test_that("GROUP_COLORS deckt genau die Gruppen von activity_group() ab", {
  # ein Typ je Gruppe; fehlt eine Farbe oder ist eine Gruppe neu, schlägt das hier an
  typen <- c("cycling", "running", "hiit", "walking", "sailing", "breathwork")
  expect_setequal(names(GROUP_COLORS), unique(activity_group(typen)))
  expect_true(all(grepl("^#[0-9A-Fa-f]{6}$", GROUP_COLORS)))
})

test_that("Konstanten für das Dashboard sind plausibel und ACWR-Grenzen geordnet", {
  expect_true(STEP_GOAL > 0)
  expect_true(ACWR_LOW < ACWR_HIGH && ACWR_HIGH < ACWR_VERY_HIGH)
})

test_that("META-Teil aus Konstanten wird als JSON-Objekt serialisiert (nicht als Liste)", {
  # as.list() erhält Namen und Reihenfolge; ein benannter Vektor würde zum Array, das Dashboard erwartet ein Objekt
  j <- jsonlite::fromJSON(jsonlite::toJSON(
    list(group_colors = as.list(GROUP_COLORS),
         acwr = list(low = ACWR_LOW, high = ACWR_HIGH, very_high = ACWR_VERY_HIGH)),
    auto_unbox = TRUE), simplifyVector = FALSE)
  expect_equal(names(j$group_colors), names(GROUP_COLORS))
  expect_equal(j$group_colors[["Rad"]], GROUP_COLORS[["Rad"]])
  expect_equal(names(j$acwr), c("low", "high", "very_high"))
  expect_equal(j$acwr$low, ACWR_LOW)
})

# ---- CSV-Leser (Pfade und Spaltentypen an einer Stelle) -----------------------------------------
test_that("Pfade der Datendateien liegen alle in data/", {
  for (f in c(F_DAILY, F_ACT, F_WEIGHT, F_ZONES, F_HR, F_WEATHER)) expect_equal(dirname(f), DIR_DATA)
  expect_equal(basename(c(F_DAILY, F_ACT, F_WEIGHT, F_ZONES, F_HR, F_WEATHER)),
               c("garmin_daily.csv", "garmin_activities.csv", "garmin_weight.csv",
                 "garmin_activity_zones.csv", "garmin_activity_hr.csv", "weather.csv"))
})

test_that("Leser geben NULL zurück, wenn die Datei fehlt", {
  nf <- file.path(tempdir(), "gibt-es-nicht.csv")
  for (rd in list(read_daily_cache, read_act_cache, read_weight_cache, read_zones_cache, read_hr_cache))
    expect_null(rd(nf))
})

test_that("read_daily_cache liest Textspalten als Text und date als Datum", {
  f <- tempfile(fileext = ".csv")
  readr::write_csv(tibble(date = as.Date("2026-10-01") + 0:1, steps = c(8000, 9000),
                          sleep_start = c("2026-09-30 22:44", NA), sleep_end = c("2026-10-01 06:30", NA),
                          hrv_status = c("BALANCED", NA), ready_level = c("MODERATE", NA), ts_status = c("PRODUCTIVE", NA)), f)
  d <- read_daily_cache(f)
  expect_s3_class(d$date, "Date")
  expect_type(d$sleep_start, "character")           # sonst würde readr "2026-09-30 22:44" als Datum/Zeit lesen
  expect_equal(d$sleep_start[1], "2026-09-30 22:44")
  expect_type(d$sleep_end, "character")
  expect_true(is.numeric(d$steps))
})

test_that("read_act_cache, read_zones_cache und read_hr_cache halten activity_id als Text", {
  # Garmin-IDs sind zu groß für 32-Bit-Zahlen; als Zahl gelesen gingen Stellen verloren
  f1 <- tempfile(fileext = ".csv"); f2 <- tempfile(fileext = ".csv"); f3 <- tempfile(fileext = ".csv")
  readr::write_csv(tibble(activity_id = "12345678901234", start = as.POSIXct("2026-10-01 07:30:00", tz = "UTC"),
                          name = "x", type_key = "cycling", distance_km = 14, duration_min = 42), f1)
  readr::write_csv(tibble(activity_id = "12345678901234", z1_s = 60, z1_low = 95), f2)
  readr::write_csv(tibble(activity_id = "12345678901234", hr_peak30 = 151, n_samples = 2400), f3)
  a <- read_act_cache(f1); z <- read_zones_cache(f2); h <- read_hr_cache(f3)
  expect_equal(a$activity_id, "12345678901234"); expect_s3_class(a$start, "POSIXct")
  expect_equal(z$activity_id, "12345678901234"); expect_true(is.numeric(z$z1_s))
  expect_equal(h$activity_id, "12345678901234"); expect_equal(h$hr_peak30, 151)
})

test_that("read_weight_cache liest die Wiegungen", {
  f <- tempfile(fileext = ".csv")
  readr::write_csv(tibble(date = as.Date("2026-10-01") + 0:2, weight_kg = c(89.4, 89.1, 89.6)), f)
  w <- read_weight_cache(f)
  expect_equal(nrow(w), 3); expect_s3_class(w$date, "Date"); expect_equal(w$weight_kg[2], 89.1)
})

# ---- Rollierende Statistik über Kalendertage ----------------------------------------------------
test_that("roll_apply erfüllt die von Hand gerechneten Fälle (dieselben prüft rollMean im JavaScript)", {
  fx <- jsonlite::fromJSON(here::here("tests", "fixtures", "rolling.json"), simplifyVector = FALSE)
  num <- function(l) vapply(l, function(v) if (is.null(v)) NA_real_ else as.numeric(v), numeric(1))
  for (cs in fx$cases) {
    got <- roll_apply(num(cs$values), as.Date(unlist(cs$dates)), cs$k, mean, cs$min_n, lag_by = cs$lag_by)
    expect_equal(got, num(cs$expected), info = cs$name)
  }
})

test_that("roll_apply zählt Kalendertage, nicht Zeilen: eine Datumslücke füllt das Fenster nicht auf", {
  d <- as.Date(c("2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-10"))
  r <- roll_apply(c(1, 2, 3, 4, 10), d, 7, mean, 3)
  expect_true(is.na(r[5]))                           # im Fenster 4.-10.1. liegen nur 2 Tage mit Wert
  expect_equal(r[4], 2.5)
})

test_that("roll_apply gibt mit beliebiger Funktion und lag_by das Fenster bis zum Vortag zurück", {
  d <- as.Date("2026-01-01") + 0:5; x <- c(2, 4, 4, 4, 5, 5)
  expect_equal(roll_apply(x, d, 3, sd, 3, lag_by = 1), c(NA, NA, NA, sd(x[1:3]), sd(x[2:4]), sd(x[3:5])))
})

test_that("roll_apply prüft die Datumsspalte", {
  expect_error(roll_apply(1:3, as.Date("2026-01-01") + c(0, 0, 1), 7, mean, 1), "Dubletten")
  expect_error(roll_apply(1:3, as.Date("2026-01-01") + c(2, 1, 0), 7, mean, 1), "aufsteigend")
  expect_error(roll_apply(1:3, c(as.Date("2026-01-01"), NA, as.Date("2026-01-03")), 7, mean, 1), "fehlende Werte")
  expect_error(roll_apply(1:3, as.Date("2026-01-01") + 0:1, 7, mean, 1), "gleich lang")
})

test_that("daily_load_recovery bildet ACWR-Fenster über Kalendertage, auch bei Lücken in den Tageswerten", {
  days <- as.Date("2026-06-01") + 0:39
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80, hrv_night = 40) |>
    filter(!(date >= as.Date("2026-06-21") & date <= as.Date("2026-06-25")))      # fünf Tage fehlen in den Tageswerten
  acts <- tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  dl <- daily_load_recovery(daily, acts)
  at <- function(day) dl$acute_d[dl$date == as.Date(day)]
  expect_true(is.na(at("2026-06-29")))               # Fenster 23.-29.6.: nur 4 Tage vorhanden (26.-29.6.)
  expect_equal(at("2026-06-30"), 50)                 # Fenster 24.-30.6.: 5 Tage vorhanden (26.-30.6.)
})

# ---- Hilfen für die Inferenz-Module ---------------------------------------------------------------
test_that("nw_effect liefert Schätzung, Newey-West-SE, t-Intervall und p-Wert eines Koeffizienten", {
  set.seed(11); n <- 120; x <- rnorm(n); y <- 2 + 0.5 * x + as.numeric(arima.sim(list(ar = 0.5), n))
  f <- lm(y ~ x)
  e <- nw_effect(f, "x", lag = 3)
  se <- sqrt(sandwich::NeweyWest(f, lag = 3, prewhite = FALSE, adjust = TRUE)["x", "x"])
  expect_equal(e$est, unname(coef(f)["x"]))
  expect_equal(e$se, se)
  expect_equal(e$df, f$df.residual)
  tc <- qt(0.975, f$df.residual)
  expect_equal(c(e$lo, e$hi), unname(coef(f)["x"]) + c(-1, 1) * tc * se)
  expect_equal(e$p, unname(2 * pt(-abs(coef(f)["x"] / se), f$df.residual)))
  expect_false(is.null(names(e)) || anyNA(unlist(e)))
  expect_null(names(e$est))                           # kein Namensrest aus coef()
})

test_that("nw_effect: ein größerer Lag verbreitert das Intervall bei autokorrelierten Daten", {
  set.seed(3); n <- 200; x <- as.numeric(arima.sim(list(ar = 0.8), n)); y <- 0.3 * x + as.numeric(arima.sim(list(ar = 0.8), n))
  f <- lm(y ~ x)
  expect_gt(nw_effect(f, "x", 7)$se, nw_effect(f, "x", 0)$se)
})

test_that("nw_effect trifft den Faktor-Term eines Modells mit Wochentag", {
  set.seed(2); n <- 100; g <- rbinom(n, 1, 0.3) == 1; wd <- factor(rep(1:5, length.out = n)); y <- 1 + 0.8 * g + rnorm(n)
  f <- lm(y ~ g + wd)
  e <- nw_effect(f, "gTRUE", 3)
  expect_equal(e$est, unname(coef(f)["gTRUE"]))
  expect_equal(e$df, n - 6)
})

test_that("ln_or_na und pct_from_ln: nur positive Werte, Prozent aus ln-Differenzen", {
  expect_warning(r <- ln_or_na(c(40, 0, -3, NA)), NA)    # keine Warnung bei 0 oder negativen Werten
  expect_equal(r, c(log(40), NA, NA, NA))
  expect_equal(ln_or_na(numeric()), numeric())
  expect_equal(pct_from_ln(log(1.1)), 10)
  expect_equal(pct_from_ln(0), 0)
  expect_equal(pct_from_ln(log(0.8)), -20)
  expect_equal(pct_from_ln(ln_or_na(c(50, 55))[2] - ln_or_na(c(50, 55))[1]), 10)   # 50 -> 55 sind +10 %
})
