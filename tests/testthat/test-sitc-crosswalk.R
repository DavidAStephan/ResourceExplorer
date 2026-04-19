test_that("load_sitc_crosswalk writes all configured commodities", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse      = file.path(tmp, "wh.duckdb"),
      schema_sql     = system.file("sql", "schema.sql", package = "resourcetracker"),
      sitc_crosswalk = system.file("extdata", "sitc_crosswalk.csv", package = "resourcetracker"),
      logs           = file.path(tmp, "logs")
    ),
    commodities = c("iron_ore", "coal", "lng", "other"),
    logging     = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  xw <- load_sitc_crosswalk(cfg)
  expect_s3_class(xw, "tbl_df")
  expect_true(all(c("iron_ore", "coal", "lng") %in% xw$commodity))
  expect_true(any(xw$is_primary))
})

test_that("load_sitc_crosswalk errors if a required commodity is missing", {
  tmp <- withr::local_tempdir()
  csv <- file.path(tmp, "xw.csv")
  readr::write_csv(tibble::tibble(
    commodity  = "iron_ore",
    sitc       = "281",
    is_primary = TRUE,
    notes      = "only iron"
  ), csv)

  cfg <- list(
    paths = list(
      warehouse      = file.path(tmp, "wh.duckdb"),
      schema_sql     = system.file("sql", "schema.sql", package = "resourcetracker"),
      sitc_crosswalk = csv,
      logs           = file.path(tmp, "logs")
    ),
    commodities = c("iron_ore", "coal", "lng", "other"),
    logging     = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  expect_error(load_sitc_crosswalk(cfg), "missing rows")
})
