test_that("parse_portwatch_features handles empty feature list", {
  body <- '{"features": []}'
  out <- parse_portwatch_features(body)
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 0)
  expect_named(out, c("obs_date", "port_id", "commodity", "tonnage",
                      "vessel_count", "ingested_at"))
})

test_that("parse_portwatch_features maps IMF field names", {
  body <- jsonlite::toJSON(list(
    features = list(
      list(attributes = list(
        ObsDate        = 1704067200000,  # 2024-01-01 UTC in ms
        PortID         = "PHED",
        CommodityGroup = "Dry bulk",
        Tonnage        = 123456.0,
        VesselCount    = 7L
      )),
      list(attributes = list(
        ObsDate        = 1704153600000,
        PortID         = "DAMP",
        CommodityGroup = "Dry bulk",
        Tonnage        = 98765.0,
        VesselCount    = 4L
      ))
    )
  ), auto_unbox = TRUE)

  out <- parse_portwatch_features(as.character(body))
  expect_equal(nrow(out), 2)
  expect_equal(out$port_id, c("PHED", "DAMP"))
  expect_equal(out$tonnage, c(123456.0, 98765.0))
  expect_s3_class(out$obs_date, "Date")
})

test_that("fetch_portwatch_tonnage falls back to cache on HTTP failure", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse  = file.path(tmp, "wh.duckdb"),
      schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
      cache      = file.path(tmp, "cache"),
      logs       = file.path(tmp, "logs")
    ),
    sample = list(train_start = "2019-01-01"),
    portwatch = list(
      base_url    = "https://example.invalid/fs/0",
      countries   = "AUS",
      page_size   = 2000,
      retry       = list(max_attempts = 1, backoff_seconds = 0)
    ),
    logging = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  seed <- tibble::tibble(
    obs_date     = as.Date("2024-01-01"),
    port_id      = "PHED",
    commodity    = "Dry bulk",
    tonnage      = 1.0,
    vessel_count = 1L,
    ingested_at  = Sys.time()
  )
  cache_write(cfg, "portwatch", "daily_trade_panel", seed)

  # example.invalid doesn't resolve — fetcher errors, with_cache falls
  # back to the seeded cache above.
  out <- fetch_portwatch_tonnage(cfg, cfg$paths$warehouse)
  expect_equal(nrow(out), 1)
  expect_equal(out$port_id, "PHED")
})
