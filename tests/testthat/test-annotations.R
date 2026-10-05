source(here::here("scripts", "helpers.R"))

write_ann <- function(lines) {
  f <- tempfile(fileext = ".csv"); writeLines(lines, f); f
}
d0 <- function(...) tibble(date = as.Date("2026-07-29") + 0:5, steps = 5000, sleep_h = c(7, 3.5, 3, 4, 7, 7)) |> mutate(...)

test_that("read_annotations liest Datei, fehlende Datei ergibt leere Tabelle", {
  f <- write_ann(c("from,to,note,load_unknown,short_sleep_real",
                   "2026-07-30,2026-08-01,Segeln,TRUE,TRUE"))
  a <- read_annotations(f)
  expect_equal(nrow(a), 1); expect_equal(a$from, as.Date("2026-07-30")); expect_true(a$load_unknown)
  e <- read_annotations(tempfile(fileext = ".csv"))
  expect_equal(nrow(e), 0)
  expect_true(all(c("from", "to", "note", "load_unknown", "short_sleep_real") %in% names(e)))
})

test_that("read_annotations meldet fehlende Spalten und unlesbare Daten", {
  expect_error(read_annotations(write_ann(c("from,to,note", "2026-07-30,2026-08-01,x"))), "Spalten")
  expect_error(read_annotations(write_ann(c("from,to,note,load_unknown,short_sleep_real",
                                            "kein-datum,2026-08-01,x,TRUE,TRUE"))), "Datum")
  expect_error(read_annotations(write_ann(c("from,to,note,load_unknown,short_sleep_real",
                                            "2026-08-02,2026-08-01,x,TRUE,TRUE"))), "von.*nach")
})

test_that("apply_annotations beschriftet nur Tage im Zeitraum", {
  a <- read_annotations(write_ann(c("from,to,note,load_unknown,short_sleep_real",
                                    "2026-07-30,2026-08-01,Segeln,TRUE,TRUE")))
  d <- apply_annotations(d0(), a)
  expect_equal(d$ann_note, c(NA, "Segeln", "Segeln", "Segeln", NA, NA))
  expect_equal(d$ann_load_unknown, c(FALSE, TRUE, TRUE, TRUE, FALSE, FALSE))
  expect_equal(d$ann_short_sleep,  c(FALSE, TRUE, TRUE, TRUE, FALSE, FALSE))
})

test_that("apply_annotations ohne Annotationen liefert neutrale Spalten", {
  d <- apply_annotations(d0(), read_annotations(tempfile(fileext = ".csv")))
  expect_true(all(is.na(d$ann_note))); expect_false(any(d$ann_load_unknown)); expect_false(any(d$ann_short_sleep))
})

test_that("Annotierte kurze Nächte gelten nicht als 'Uhr nicht getragen'", {
  a <- read_annotations(write_ann(c("from,to,note,load_unknown,short_sleep_real",
                                    "2026-07-30,2026-08-01,Segeln,TRUE,TRUE")))
  d <- apply_annotations(d0(), a)
  f <- flag_daily(d, today = as.Date("2026-12-01"))
  expect_equal(f$sleep_bad, rep(FALSE, 6))
  expect_equal(clean_daily(d, today = as.Date("2026-12-01"))$sleep_h, d$sleep_h)   # nichts maskiert
  # ohne Annotation bleiben die Nächte unter der Schwelle ungültig
  expect_equal(flag_daily(d0(), today = as.Date("2026-12-01"))$sleep_bad, c(FALSE, TRUE, TRUE, TRUE, FALSE, FALSE))
})
