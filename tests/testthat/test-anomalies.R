fixture_anomaly_pw <- function() {
  dates <- seq(as.Date("2021-01-01"), as.Date("2026-04-15"), by = "day")
  set.seed(1)
  tonnage <- 1000 +
    100 * sin(2 * pi * lubridate::yday(dates) / 365) +
    stats::rnorm(length(dates), 0, 20)

  # Inject a big spike on 2026-04-10
  spike_idx <- which(dates == as.Date("2026-04-10"))
  tonnage[spike_idx] <- tonnage[spike_idx] + 500

  tibble::tibble(
    obs_date     = dates,
    port_id      = "P1",
    commodity    = "iron_ore",
    tonnage      = tonnage,
    vessel_count = 1L,
    ingested_at  = Sys.time()
  )
}

test_that("detect_anomalies flags an injected spike", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths  = list(warehouse  = file.path(tmp, "wh.duckdb"),
                  schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
                  logs       = file.path(tmp, "logs")),
    sample = list(train_end = "2023-12-31"),
    logging = list(level = "WARN")
  )
  init_logger(cfg); warehouse_init_schema(cfg)

  out <- detect_anomalies(fixture_anomaly_pw(), cfg,
                          as_of = as.Date("2026-04-15"),
                          lookback_days = 14, threshold = 2)

  expect_true(nrow(out) >= 1)
  expect_true(as.Date("2026-04-10") %in% out$obs_date)
  top <- out[1, ]
  expect_gt(abs(top$z_score), 2)
})

test_that("detect_anomalies handles empty input", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths  = list(warehouse  = file.path(tmp, "wh.duckdb"),
                  schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
                  logs       = file.path(tmp, "logs")),
    sample = list(train_end = "2023-12-31"),
    logging = list(level = "WARN")
  )
  init_logger(cfg); warehouse_init_schema(cfg)
  empty <- tibble::tibble(
    obs_date = as.Date(character()), port_id = character(),
    commodity = character(), tonnage = double(),
    vessel_count = integer(),
    ingested_at = as.POSIXct(character(), tz = "UTC")
  )
  out <- detect_anomalies(empty, cfg)
  expect_equal(nrow(out), 0)
})
