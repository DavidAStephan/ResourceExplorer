setup_cfg <- function() {
  tmp <- withr::local_tempdir(.local_envir = parent.frame(2))
  cfg <- list(
    paths  = list(warehouse_dir = file.path(tmp, "warehouse"),
                  logs          = file.path(tmp, "logs")),
    logging = list(level = "WARN")
  )
  init_logger(cfg); warehouse_init_schema(cfg)
  cfg
}

test_that("save_nowcast_run + last_nowcast_run round-trip", {
  cfg <- setup_cfg()

  row1 <- tibble::tibble(
    quarter_end    = as.Date("2026-06-30"),
    point_estimate = 150000, lower_80 = 148000, upper_80 = 152000,
    lower_95 = 145000, upper_95 = 155000, share_observed = 0.25,
    run_timestamp  = as.POSIXct("2026-04-19 10:00:00", tz = "UTC")
  )
  save_nowcast_run(cfg, row1)

  Sys.sleep(0.02)
  row2 <- row1
  row2$point_estimate <- 151000
  row2$run_timestamp  <- as.POSIXct("2026-04-19 11:00:00", tz = "UTC")
  save_nowcast_run(cfg, row2)

  last <- last_nowcast_run(cfg, as.Date("2026-06-30"))
  expect_equal(last$point_estimate, 151000)

  prior <- last_nowcast_run(cfg, as.Date("2026-06-30"),
                            exclude_run_timestamp = row2$run_timestamp)
  expect_equal(prior$point_estimate, 150000)
})

test_that("nowcast_delta returns NULL on first run", {
  cur <- tibble::tibble(
    quarter_end = as.Date("2026-06-30"),
    point_estimate = 150000, lower_80 = 148000, upper_80 = 152000,
    lower_95 = 145000, upper_95 = 155000, share_observed = 0.25,
    run_timestamp = Sys.time()
  )
  expect_null(nowcast_delta(cur, NULL))
})

test_that("nowcast_delta computes per-field deltas", {
  cur <- tibble::tibble(
    quarter_end = as.Date("2026-06-30"),
    point_estimate = 151000, lower_80 = 149000, upper_80 = 153000,
    lower_95 = 146000, upper_95 = 156000, share_observed = 0.26,
    run_timestamp = as.POSIXct("2026-04-19 11:00:00", tz = "UTC")
  )
  prev <- tibble::tibble(
    quarter_end = as.Date("2026-06-30"),
    point_estimate = 150000, lower_80 = 148000, upper_80 = 152000,
    lower_95 = 145000, upper_95 = 155000, share_observed = 0.25,
    run_timestamp = as.POSIXct("2026-04-19 10:00:00", tz = "UTC")
  )
  d <- nowcast_delta(cur, prev)
  expect_equal(d$delta_point, 1000)
  expect_equal(d$delta_upper_80, 1000)
  expect_equal(d$hours_since, 1)
})
