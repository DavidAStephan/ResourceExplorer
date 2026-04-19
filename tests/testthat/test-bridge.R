## Bridge-regression tests.
##
## We simulate a known DGP with y = α + β₁·logT + β₂·logP + β₃·lag(logy) + ε
## and verify that fit_bridge recovers the coefficients within tolerance.
## This is a strong correctness check that doesn't require real ABS/PortWatch
## data.

simulate_features <- function(n = 72, seed = 20260419, commodity = "iron_ore") {
  set.seed(seed)
  tonnage <- exp(10 + 0.01 * seq_len(n) + stats::rnorm(n, 0, 0.1))
  price   <- exp(4  + 0.02 * seq_len(n) + stats::rnorm(n, 0, 0.1))
  log_y   <- numeric(n)
  log_y[1] <- log(1000)
  beta0 <- 2; b_t <- 0.9; b_p <- 1.1; b_l <- 0.3
  for (i in 2:n) {
    log_y[i] <- beta0 + b_t * log(tonnage[i]) + b_p * log(price[i]) +
                b_l * log_y[i - 1] + stats::rnorm(1, 0, 0.05)
  }
  tibble::tibble(
    commodity      = commodity,
    month_end      = seq(as.Date("2018-01-01"), by = "month", length.out = n) |>
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
}

test_that("fit_bridge recovers known DGP coefficients within tolerance", {
  feats <- simulate_features(n = 96)
  cfg <- list(
    sample = list(train_end = "2023-12-31"),
    commodities = "iron_ore"
  )
  fits <- fit_bridge(feats, cfg)
  expect_named(fits, "iron_ore")

  co <- stats::coef(fits$iron_ore$fit)
  expect_equal(co[["log_tonnage_sa"]], 0.9, tolerance = 0.1)
  expect_equal(co[["log_price"]],      1.1, tolerance = 0.1)
  expect_equal(co[["log_y_lag1"]],     0.3, tolerance = 0.1)

  diag <- fits$iron_ore$diagnostics
  expect_gt(diag$r_squared, 0.9)
  expect_true(diag$dw_stat > 1 && diag$dw_stat < 3)
})

test_that("predict_bridge is recursive — h-step uses predicted lag", {
  feats <- simulate_features(n = 96)
  cfg <- list(sample = list(train_end = "2023-12-31"),
              commodities = "iron_ore")
  fits <- fit_bridge(feats, cfg)

  newdata <- feats |>
    dplyr::filter(.data$month_end >= as.Date("2024-01-31"),
                  .data$month_end <= as.Date("2024-03-31"))

  preds <- predict_bridge(fits, newdata)
  expect_equal(nrow(preds), 3)
  expect_true(all(is.finite(preds$yhat_log)))

  # Confirm month 2's log_y_lag1 input was month 1's prediction, not the
  # observed lag passed in. Compare: manually recompute using fitted
  # coefficients + observed lag and check it DIFFERS from predict_bridge's
  # output for month 2+.
  co <- stats::coef(fits$iron_ore$fit)
  manual_month2 <- co["(Intercept)"] +
    co["log_tonnage_sa"] * newdata$log_tonnage_sa[2] +
    co["log_price"]      * newdata$log_price[2] +
    co["log_y_lag1"]     * newdata$log_y_lag1[2]   # observed, not predicted
  expect_false(isTRUE(all.equal(preds$yhat_log[2],
                                as.numeric(manual_month2))))
})

test_that("fit_bridge skips commodities with too few observations", {
  feats <- simulate_features(n = 18)
  cfg <- list(sample = list(train_end = "2023-12-31"),
              commodities = "iron_ore")
  fits <- fit_bridge(feats, cfg)
  expect_null(fits$iron_ore)
})
