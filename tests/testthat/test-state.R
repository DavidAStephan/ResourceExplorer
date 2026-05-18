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

.sample_rows <- function(q = as.Date("2026-06-30"), ts = Sys.time(),
                         commodities = c("iron_ore","coal")) {
  tibble::tibble(
    commodity         = commodities,
    quarter_end       = q,
    point_estimate_Mt = c(230.0, 95.0),
    lower_80          = c(220.0, 90.0),
    upper_80          = c(240.0, 100.0),
    lower_95          = c(210.0, 85.0),
    upper_95          = c(250.0, 105.0),
    share_observed    = 0.25,
    run_timestamp     = ts
  )
}

test_that("save_nowcast_run + last_nowcast_run round-trip per commodity", {
  cfg <- setup_cfg()
  row1 <- .sample_rows(ts = as.POSIXct("2026-04-19 10:00:00", tz = "UTC"))
  save_nowcast_run(cfg, row1)

  Sys.sleep(0.02)
  row2 <- .sample_rows(ts = as.POSIXct("2026-04-19 11:00:00", tz = "UTC"))
  row2$point_estimate_Mt <- c(232.0, 96.5)
  save_nowcast_run(cfg, row2)

  last <- last_nowcast_run(cfg, "iron_ore", as.Date("2026-06-30"))
  expect_equal(last$point_estimate, 232.0)

  prior <- last_nowcast_run(cfg, "iron_ore", as.Date("2026-06-30"),
                            exclude_run_timestamp = row2$run_timestamp[1])
  expect_equal(prior$point_estimate, 230.0)
})

test_that("nowcast_delta returns NULL on first run", {
  cur <- .sample_rows()[1, ]
  expect_null(nowcast_delta(cur, NULL))
})

test_that("nowcast_delta computes per-field deltas", {
  cur <- .sample_rows(ts = as.POSIXct("2026-04-19 11:00:00", tz = "UTC"))[1, ]
  prev <- tibble::tibble(
    commodity      = "iron_ore",
    quarter_end    = as.Date("2026-06-30"),
    point_estimate = 229,
    lower_80 = 219, upper_80 = 239,
    lower_95 = 209, upper_95 = 249,
    share_observed = 0.20,
    run_timestamp  = as.POSIXct("2026-04-19 10:00:00", tz = "UTC")
  )
  d <- nowcast_delta(cur, prev)
  expect_equal(d$delta_point, 1)
  expect_equal(d$delta_upper_80, 1)
  expect_equal(d$hours_since, 1)
  expect_equal(d$commodity, "iron_ore")
})
