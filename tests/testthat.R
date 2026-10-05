# Aufruf (aus dem Projektordner "fitness"):
#   Rscript tests/testthat.R
suppressPackageStartupMessages({ library(testthat); library(dplyr); library(tibble) })
test_dir(here::here("tests", "testthat"), reporter = "summary", stop_on_failure = TRUE)
