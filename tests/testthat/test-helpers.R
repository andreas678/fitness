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
