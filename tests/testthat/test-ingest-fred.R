test_that("fetch_fred_prices uses cache when FRED_API_KEY is missing", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse  = file.path(tmp, "wh.duckdb"),
      schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
      cache      = file.path(tmp, "cache"),
      logs       = file.path(tmp, "logs")
    ),
    fred = list(series_ids = c("PIORECRUSDM", "PCOALAUUSDM")),
    logging = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  seed <- tibble::tibble(
    obs_date  = as.Date(c("2024-01-31", "2024-01-31")),
    series_id = c("PIORECRUSDM", "PCOALAUUSDM"),
    value     = c(120, 140)
  )
  cache_write(cfg, "fred", "commodity_prices", seed)

  withr::with_envvar(c(FRED_API_KEY = ""), {
    out <- fetch_fred_prices(cfg, cfg$paths$warehouse)
    expect_equal(nrow(out), 2)
    expect_setequal(out$series_id, c("PIORECRUSDM", "PCOALAUUSDM"))
  })
})

test_that("fetch_fred_prices errors when no key and no cache", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse  = file.path(tmp, "wh.duckdb"),
      schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
      cache      = file.path(tmp, "cache"),
      logs       = file.path(tmp, "logs")
    ),
    fred = list(series_ids = c("PIORECRUSDM")),
    logging = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  withr::with_envvar(c(FRED_API_KEY = ""), {
    expect_error(fetch_fred_prices(cfg, cfg$paths$warehouse),
                 "no cache available")
  })
})
