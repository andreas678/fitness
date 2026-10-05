# Aufruf (aus dem Projektordner "fitness"):
#   Rscript tests/testthat.R                                                       # R-Tests
#   ~/.virtualenvs/r-garmin/bin/python -m unittest discover -s tests/python        # Python-Tests
suppressPackageStartupMessages({ library(testthat); library(dplyr); library(tibble) })
test_dir(here::here("tests", "testthat"), reporter = "summary", stop_on_failure = TRUE)
