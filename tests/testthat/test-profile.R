source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

with_env <- function(vars, code) {
  old <- Sys.getenv(names(vars), unset = NA)
  do.call(Sys.setenv, as.list(vars))
  on.exit(for (n in names(old)) if (is.na(old[[n]])) Sys.unsetenv(n) else do.call(Sys.setenv, setNames(list(old[[n]]), n)))
  force(code)
}
today <- as.Date("2026-10-05")

test_that("athlete_profile: HRMAX aus der Umgebung heißt 'eingestellt', Plausibilitätsgrenze aus Tanaka + 30", {
  p <- with_env(c(BIRTHDAY = "01-01-1974", HRMAX = "182", GENDER = "male"), athlete_profile(54, today))
  expect_equal(p$age, 52); expect_equal(p$hrmax, 182)
  expect_equal(p$hrmax_source, "eingestellt via HRMAX")
  expect_equal(p$hr_ceiling, round(208 - 0.7 * 52) + 30)      # 202
})

test_that("athlete_profile: ohne HRMAX wird nach Tanaka geschätzt", {
  p <- with_env(c(BIRTHDAY = "01-01-1974", HRMAX = "", GENDER = "male"), athlete_profile(54, today))
  expect_equal(p$hrmax, round(208 - 0.7 * 52)); expect_equal(p$hrmax_source, "geschätzt (Tanaka)")
})

p0 <- list(hrmax = 182, hr_ceiling = 202)
acts <- tibble(activity_id = as.character(1:6), max_hr = c(160, 190, 195, 201, 223, NA))
hr <- tibble(activity_id = as.character(1:5), hr_peak30 = c(150, 178, 186, 194, 212), hr_max_raw = c(160, 190, 195, 201, 223))

test_that("hr_peak_stats trennt Überschreitung, Artefakt und Rohmaximum", {
  s <- hr_peak_stats(acts, hr, p0)
  expect_equal(s$n_hr, 5); expect_equal(s$n_peak, 5)
  expect_equal(s$n_exceed_raw, 4)                 # max_hr > 182: 190, 195, 201, 223
  expect_equal(s$n_exceed, 2)                     # 30-s-Spitze über HFmax und unter der Grenze: 186, 194
  expect_equal(s$n_artifact, 1)                   # 212 > 202
  expect_equal(s$obs_max, 194)                    # höchster 30-s-Wert ohne Artefakte
})

test_that("hr_peak_stats ohne Zeitreihen liefert nur Rohzahlen", {
  s <- hr_peak_stats(acts, NULL, p0)
  expect_equal(s$n_peak, 0); expect_equal(s$n_exceed_raw, 4)
  expect_true(is.na(s$n_exceed) && is.na(s$obs_max))
})

test_that("hr_peak_stats ohne Plausibilitätsgrenze klassifiziert keine Artefakte", {
  s <- hr_peak_stats(acts, hr, list(hrmax = 182, hr_ceiling = NA_real_))
  expect_equal(s$n_artifact, 0); expect_equal(s$obs_max, 212)
})

test_that("hr_peak_stats meldet 'HFmax zu niedrig' erst oberhalb der Sensor-Toleranz", {
  expect_true(hr_peak_stats(acts, hr, list(hrmax = 182, hr_ceiling = 202))$low)          # 194 > 182 + 3
  expect_false(hr_peak_stats(acts, hr, list(hrmax = 192, hr_ceiling = 202))$low)         # 194 <= 192 + 3
  expect_true(hr_peak_stats(acts, hr, list(hrmax = 192, hr_ceiling = 202), tol = 1)$low)
  expect_false(hr_peak_stats(acts, NULL, p0)$low)                                        # ohne Pulskurven keine Aussage
})

# Sensor-Phasen: Handgelenk bis 17.09.2026, Brustgurt (HIIT, Indoor-Rad) ab 18.09.2026
acts_s <- tibble(
  activity_id = as.character(1:7), max_hr = c(223, 199, 201, 177, 172, 177, 190),
  start = as.POSIXct(c("2026-05-11 17:01", "2026-06-22 17:01", "2026-09-17 17:02", "2026-09-18 17:00",
                       "2026-10-05 17:00", "2026-10-07 19:19", "2026-10-08 18:02"), tz = "UTC"),
  type_key = c("hiit", "hiit", "hiit", "hiit", "hiit", "indoor_cycling", "cycling"))
hr_s <- tibble(activity_id = as.character(1:7), hr_peak30 = c(212, 193.9, 186.1, 175.7, 170, 175.5, 185),
               hr_max_raw = c(223, 199, 201, 177, 172, 177, 190))
p_s <- list(hrmax = 178, hr_ceiling = 202)
strap_day <- as.Date("2026-09-18")

test_that("hr_peak_stats mit strap_from wertet nur Brustgurt-Einheiten (HIIT und Indoor-Rad ab dem Stichtag)", {
  s <- hr_peak_stats(acts_s, hr_s, p_s, strap_from = strap_day)
  expect_equal(s$basis, "strap")
  expect_equal(s$n_hr, 3); expect_equal(s$n_peak, 3)          # Ids 4, 5, 6; die Pendelfahrt (7) hat unbekannten Sensor
  expect_equal(s$n_exceed_raw, 0)                              # 177, 172, 177 <= 178
  expect_equal(s$n_exceed, 0); expect_equal(s$n_artifact, 0)
  expect_equal(s$obs_max, 175.7)
  expect_false(s$low)                                          # die Handgelenk-Spitzen 186-194 lösen keinen Alarm mehr aus
  expect_equal(s$n_wrist, 4)                                   # Ids 1, 2, 3, 7
  expect_equal(s$obs_max_wrist, 193.9)                         # 212 ist Artefakt und zählt nicht
  expect_equal(s$strap_from, strap_day)
})

test_that("hr_peak_stats: Stichtag ist inklusive, der Tag davor zählt als Handgelenk", {
  s <- hr_peak_stats(acts_s, hr_s, p_s, strap_from = as.Date("2026-09-17"))
  expect_equal(s$n_hr, 4)                                      # Id 3 (17.09.) kommt dazu
  expect_equal(s$obs_max, 186.1); expect_true(s$low)           # 186,1 > 178 + 3
  s2 <- hr_peak_stats(acts_s, hr_s, p_s, strap_from = as.Date("2026-09-19"))
  expect_equal(s2$n_hr, 2)                                     # Id 4 (18.09.) fällt weg
})

test_that("hr_peak_stats ohne strap_from oder ohne Brustgurt-Einheit zählt alle Einheiten", {
  a <- hr_peak_stats(acts_s, hr_s, p_s)
  expect_equal(a$basis, "all"); expect_equal(a$n_hr, 7); expect_equal(a$n_wrist, 0)
  expect_equal(a$n_artifact, 1); expect_equal(a$obs_max, 193.9); expect_true(a$low)
  f <- hr_peak_stats(acts_s, hr_s, p_s, strap_from = as.Date("2027-01-01"))   # Stichtag in der Zukunft
  expect_equal(f$basis, "all"); expect_equal(f$obs_max, 193.9)
  expect_equal(hr_peak_stats(acts_s, hr_s, p_s, strap_from = NA)$basis, "all")
})

# ---- Hilfen: Tanaka, Herzfrequenzreserve, Zonengrenzen -----------------------------------------
test_that("tanaka_hrmax rundet 208 - 0,7 x Alter", {
  expect_equal(tanaka_hrmax(52), 172)      # 208 - 36,4 = 171,6
  expect_equal(tanaka_hrmax(c(30, 40)), c(187, 180))
  expect_true(is.na(tanaka_hrmax(NA_real_)))
})

test_that("hrr_frac: Anteil der Herzfrequenzreserve, standardmäßig auf 0 bis 1 begrenzt", {
  p <- list(rhr_ref = 50, hrmax = 190)
  expect_equal(hrr_frac(c(50, 120, 190), p), c(0, 0.5, 1))
  expect_equal(hrr_frac(c(40, 200), p), c(0, 1))                       # begrenzt
  expect_equal(hrr_frac(c(40, 200), p, clip = FALSE), c(-10 / 140, 150 / 140))
  m <- matrix(c(50, 120, 190, 260), 2)
  expect_equal(hrr_frac(m, p), matrix(c(0, 0.5, 1, 1), 2))             # Matrizen (Zonenmitten) bleiben Matrizen
  expect_true(is.na(hrr_frac(NA_real_, p)))
})

test_that("ZONE_EDGES liegen den Zonen und der Zonenzuordnung zugrunde", {
  expect_equal(ZONE_EDGES, c(.5, .6, .7, .8, .9))
  p <- list(rhr_ref = 50, hrmax = 190)
  w <- with_env(c(BIRTHDAY = "01-01-1974", HRMAX = "190", GENDER = "male"), athlete_profile(50, today))$zones
  expect_equal(w$lo, round(50 + 140 * ZONE_EDGES))
  expect_equal(w$hi, round(50 + 140 * c(ZONE_EDGES[-1], 1)))
  # Zuordnung in session_load: je Zone ein Beispiel (HF bei 55, 65, 75, 85, 95 % der Reserve, dazu eine unter Z1)
  hf <- 50 + 140 * c(.4, .55, .65, .75, .85, .95)
  acts <- tibble(activity_id = as.character(1:6), type_key = "hiit", avg_hr = hf, duration_min = 30)
  s <- session_load(acts, c(p, list(trimp_b = 1.92)))
  expect_equal(s$zone, c("<Z1", paste0("Z", 1:5)))
})

# ---- Banister-Koeffizienten je Geschlecht ---------------------------------------------------------
test_that("athlete_profile liefert die Banister-Koeffizienten für Männer und Frauen", {
  env <- function(g) c(BIRTHDAY = "01-01-1974", HRMAX = "182", GENDER = g)
  m <- with_env(env("male"),   athlete_profile(54, today))
  f <- with_env(env("female"), athlete_profile(54, today))
  expect_equal(c(m$trimp_a, m$trimp_b), c(0.64, 1.92))
  expect_equal(c(f$trimp_a, f$trimp_b), c(0.86, 1.67))
  expect_equal(with_env(env("w"), athlete_profile(54, today))$trimp_a, 0.86)            # Kürzel wie bisher
})

test_that("athlete_profile warnt bei fehlendem oder unbekanntem GENDER und rechnet dann wie für Männer", {
  env <- function(g) c(BIRTHDAY = "01-01-1974", HRMAX = "182", GENDER = g)
  expect_warning(p <- with_env(env(""), athlete_profile(54, today)), "GENDER")
  expect_equal(c(p$trimp_a, p$trimp_b), c(0.64, 1.92))
  expect_warning(with_env(env("divers"), athlete_profile(54, today)), "divers")
  expect_warning(with_env(env("male"), athlete_profile(54, today)), NA)                 # gesetzt: keine Warnung
  expect_warning(with_env(env("female"), athlete_profile(54, today)), NA)
})
