test_that("load_config returns all expected top-level keys", {
  cfg <- load_config(testthat::test_path("fixtures", "config.yml"))

  expect_type(cfg, "list")
  expect_true(all(c("paths", "sample", "commodities", "portwatch",
                    "abs", "fred", "nowcast", "logging") %in% names(cfg)))
})

test_that("load_config fails loudly on missing file", {
  expect_error(load_config("does_not_exist.yml"), "not found")
})

test_that("configured commodity list is the short-list", {
  cfg <- load_config(testthat::test_path("fixtures", "config.yml"))
  expect_setequal(cfg$commodities, c("iron_ore", "coal", "lng", "other"))
})
