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
