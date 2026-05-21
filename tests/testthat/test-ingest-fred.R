## FRED demand-indicator ingest tests.
## The pipeline only ever consumes the long-tibble output, so we test
## the parser/aggregator paths + the graceful-degradation behaviour
## when the API key is unset. Network calls are mocked.

test_that("expand_fred_series_map flattens nested config to pairs", {
  series <- list(
    iron_ore     = c(cli     = "CHNLOLITOAASTSAM"),
    coal_thermal = c(exports = "XTEXVA01CNM667S")
  )
  out <- expand_fred_series_map(series)
  expect_equal(nrow(out), 2)
  expect_equal(sort(out$commodity), c("coal_thermal", "iron_ore"))
  expect_equal(sort(out$label),     c("cli", "exports"))
  expect_equal(sort(out$series_id), c("CHNLOLITOAASTSAM", "XTEXVA01CNM667S"))
})

test_that("expand_fred_series_map fails fast when a series entry is unnamed", {
  bad <- list(iron_ore = c("CHNLOLITOAASTSAM"))  # no label
  expect_error(expand_fred_series_map(bad), "must be named")
})

test_that("aggregate_fred_quarterly averages months to quarter mean", {
  monthly <- tibble::tibble(
    commodity = "iron_ore",
    series    = "cli",
    series_id = "CHNLOLITOAASTSAM",
    month_end = as.Date(c("2024-01-31", "2024-02-29", "2024-03-31",
                          "2024-04-30")),
    value     = c(100, 101, 102, 110)
  )
  out <- aggregate_fred_quarterly(monthly)
  expect_equal(nrow(out), 2)
  q1 <- dplyr::filter(out, quarter_end == as.Date("2024-03-31"))
  q2 <- dplyr::filter(out, quarter_end == as.Date("2024-06-30"))
  expect_equal(q1$value, 101)        # mean(100, 101, 102)
  expect_equal(q2$value, 110)        # only April observed
  expect_equal(round(q1$log_value, 4), round(log(101), 4))
})

test_that("aggregate_fred_quarterly returns the typed empty tibble on zero rows", {
  empty <- tibble::tibble(commodity = character(), series = character(),
                          series_id = character(),
                          month_end = as.Date(character()),
                          value = double())
  out <- aggregate_fred_quarterly(empty)
  expect_equal(nrow(out), 0)
  expect_named(out, c("quarter_end", "commodity", "series", "series_id",
                      "value", "log_value"))
})

test_that("fetch_fred_demand short-circuits when FRED_API_KEY is unset", {
  cfg <- list(
    paths = list(warehouse_dir = tempfile(), cache = tempfile()),
    sample = list(train_start = as.Date("2019-01-01")),
    fred = list(
      api_key_env = "FRED_API_KEY_TEST_UNSET",  # guaranteed unset
      series = list(iron_ore = c(cli = "CHNLOLITOAASTSAM"))
    )
  )
  fs::dir_create(cfg$paths$warehouse_dir)
  fs::dir_create(cfg$paths$cache)
  withr::local_envvar(FRED_API_KEY_TEST_UNSET = "")

  out <- fetch_fred_demand(cfg, db_ready = NULL)
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 0)
  expect_named(out, c("quarter_end", "commodity", "series", "value",
                      "log_value", "ingested_at"))
})

test_that("fetch_fred_demand short-circuits when no series are configured", {
  cfg <- list(
    paths = list(warehouse_dir = tempfile(), cache = tempfile()),
    sample = list(train_start = as.Date("2019-01-01")),
    fred = list(api_key_env = "FRED_API_KEY_TEST_ANY", series = list())
  )
  fs::dir_create(cfg$paths$warehouse_dir)
  fs::dir_create(cfg$paths$cache)
  withr::local_envvar(FRED_API_KEY_TEST_ANY = "anything")

  out <- fetch_fred_demand(cfg, db_ready = NULL)
  expect_equal(nrow(out), 0)
})
