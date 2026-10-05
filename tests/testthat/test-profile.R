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
