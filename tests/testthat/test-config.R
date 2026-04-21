test_that("load_config returns all expected top-level keys", {
  cfg <- load_config(testthat::test_path("fixtures", "config.R"))

  expect_type(cfg, "list")
  expect_true(all(c("paths", "sample", "commodities", "portwatch",
                    "disr", "nowcast", "bridge", "logging") %in% names(cfg)))
})

test_that("load_config fails loudly on missing file", {
  expect_error(load_config("does_not_exist.R"), "not found")
})

test_that("configured commodity list is the short-list", {
  cfg <- load_config(testthat::test_path("fixtures", "config.R"))
  expect_setequal(cfg$commodities, c("iron_ore", "coal"))
})

test_that("load_config rejects a file that does not return a list", {
  tmp <- tempfile(fileext = ".R")
  writeLines("42", tmp)
  on.exit(unlink(tmp), add = TRUE)
  expect_error(load_config(tmp), "list as its final expression")
})
