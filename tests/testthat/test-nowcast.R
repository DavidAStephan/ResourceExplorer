## Nowcast: simulate features + fits + deflators, confirm run_nowcast
## produces valid point estimate and bands with the expected shrinkage.

simulate_fits_and_deflators <- function(commodities = c("iron_ore", "coal"),
                                        n_train = 72, seed = 20260419) {
  feats <- purrr::map_dfr(commodities, function(com) {
    set.seed(match(com, commodities))
    tonnage <- exp(10 + stats::rnorm(n_train, 0, 0.1))
    price   <- exp(4  + stats::rnorm(n_train, 0, 0.1))
    log_y <- numeric(n_train); log_y[1] <- log(1000)
    for (i in 2:n_train) {
      log_y[i] <- 2 + 0.9 * log(tonnage[i]) + 1.0 * log(price[i]) +
                  0.3 * log_y[i - 1] + stats::rnorm(1, 0, 0.1)
    }
    tibble::tibble(
      commodity      = com,
      month_end      = seq(as.Date("2019-01-01"), by = "month", length.out = n_train) |>
                         (\(d) lubridate::ceiling_date(d, "month") - 1)(),
      y_aud_m        = exp(log_y),
      tonnage, tonnage_sa = tonnage, price,
      log_y,
      log_tonnage_sa = log(tonnage),
      log_price      = log(price),
      log_y_lag1     = dplyr::lag(log_y)
    )
  })

  cfg <- list(
    sample      = list(train_end = "2023-12-31", valid_start = "2024-01-01"),
    commodities = commodities,
    nowcast     = list(bootstrap_reps = 100, seed = seed)
  )
  fits <- fit_bridge(feats, cfg)

  # Synthetic 5302.0: deflator ≈ 1.25 across recent quarters.
  quarters <- seq(as.Date("2019-03-31"), as.Date("2023-12-31"), by = "quarter") |>
    (\(d) lubridate::ceiling_date(d, "quarter") - 1)()
  abs_5302 <- tibble::tibble(
    quarter_end          = quarters,
    series_id            = "GOODS",
    value_current_aud_m  = seq(100, by = 5, length.out = length(quarters)),
    value_chainvol_aud_m = seq( 80, by = 4, length.out = length(quarters)),
    ingested_at          = Sys.time()
  )
  deflators <- implicit_deflator(abs_5302)

  list(features = feats, fits = fits, deflators = deflators, cfg = cfg)
}

test_that("run_nowcast returns the full one-row tibble contract", {
  s <- simulate_fits_and_deflators()
  out <- run_nowcast(s$fits, s$features, s$deflators, s$cfg,
                     as_of = as.Date("2024-02-15"))
  expect_equal(nrow(out), 1)
  expect_named(out, c("quarter_end", "point_estimate",
                      "lower_80", "upper_80", "lower_95", "upper_95",
                      "share_observed", "run_timestamp"))
  expect_true(out$point_estimate > 0)
  expect_lt(out$lower_80, out$point_estimate)
  expect_gt(out$upper_80, out$point_estimate)
  expect_lt(out$lower_95, out$lower_80)
  expect_gt(out$upper_95, out$upper_80)
})

test_that("bootstrap bands shrink as more of the quarter is observed", {
  s <- simulate_fits_and_deflators()

  early <- run_nowcast(s$fits, s$features, s$deflators, s$cfg,
                       as_of = as.Date("2024-01-05"))
  late  <- run_nowcast(s$fits, s$features, s$deflators, s$cfg,
                       as_of = as.Date("2024-03-28"))

  width_early <- early$upper_80 - early$lower_80
  width_late  <- late$upper_80  - late$lower_80
  expect_lt(width_late, width_early)
})

test_that("empty fit list returns a nowcast row with NA estimate", {
  s <- simulate_fits_and_deflators()
  out <- run_nowcast(list(), s$features, s$deflators, s$cfg,
                     as_of = as.Date("2024-02-15"))
  expect_equal(nrow(out), 1)
  expect_true(is.na(out$point_estimate))
})
