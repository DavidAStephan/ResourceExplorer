## Backtest test — uses simulated features with a known DGP and a
## synthetic ABS 5302.0 actual series. We verify that backtest_rmse
## runs end-to-end and produces the expected columns and row count.

simulate_feature_panel <- function(n_per_com = 72,
                                   commodities = c("iron_ore", "coal",
                                                   "lng", "other")) {
  purrr::map_dfr(commodities, function(com) {
    set.seed(switch(com, iron_ore = 1, coal = 2, lng = 3, other = 4))
    n <- n_per_com
    tonnage <- exp(10 + stats::rnorm(n, 0, 0.1))
    price   <- exp(4  + stats::rnorm(n, 0, 0.1))
    log_y <- numeric(n); log_y[1] <- log(1000)
    for (i in 2:n) {
      log_y[i] <- 2 + 0.9 * log(tonnage[i]) + 1.0 * log(price[i]) +
                  0.3 * log_y[i - 1] + stats::rnorm(1, 0, 0.05)
    }
    tibble::tibble(
      commodity      = com,
      month_end      = seq(as.Date("2019-01-01"), by = "month", length.out = n) |>
                         (\(d) lubridate::ceiling_date(d, "month") - 1)(),
      y_aud_m        = exp(log_y),
      tonnage        = tonnage,
      tonnage_sa     = tonnage,
      price          = price,
      log_y          = log_y,
      log_tonnage_sa = log(tonnage),
      log_price      = log(price),
      log_y_lag1     = dplyr::lag(log_y)
    )
  })
}

test_that("backtest_rmse produces one row per validation quarter", {
  feats <- simulate_feature_panel(n_per_com = 72)

  quarters <- seq(as.Date("2019-03-31"), as.Date("2024-09-30"), by = "quarter") |>
    (\(d) lubridate::ceiling_date(d, "quarter") - 1)()
  abs_5302 <- tibble::tibble(
    quarter_end          = quarters,
    series_id            = "GOODS",
    value_current_aud_m  = seq(100000, by = 5000, length.out = length(quarters)),
    value_chainvol_aud_m = seq( 85000, by = 3000, length.out = length(quarters)),
    ingested_at          = Sys.time()
  )

  cfg <- list(
    sample      = list(train_end   = "2023-12-31",
                       valid_start = "2024-01-01"),
    commodities = c("iron_ore", "coal", "lng", "other")
  )

  out <- backtest_rmse(feats, abs_5302, cfg)
  expect_named(out, c("quarter_end", "actual", "point_estimate",
                      "naive_srw", "err", "err_naive"))
  expect_gt(nrow(out), 0)
  expect_true(all(out$quarter_end >= as.Date("2024-01-01")))
})

test_that("backtest_rmse returns empty tibble when no valid quarters", {
  feats <- simulate_feature_panel()
  abs_5302 <- tibble::tibble(
    quarter_end          = as.Date(character()),
    series_id            = character(),
    value_current_aud_m  = double(),
    value_chainvol_aud_m = double(),
    ingested_at          = as.POSIXct(character(), tz = "UTC")
  )
  cfg <- list(
    sample = list(train_end = "2023-12-31", valid_start = "2024-01-01"),
    commodities = c("iron_ore", "coal", "lng", "other")
  )
  out <- backtest_rmse(feats, abs_5302, cfg)
  expect_equal(nrow(out), 0)
})
