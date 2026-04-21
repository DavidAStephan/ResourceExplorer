## Bridge-regression tests. Covers both `aggregate` and `midas` specs.

simulate_features <- function(n_q = 40, seed = 20260419,
                              commodity = "iron_ore") {
  set.seed(seed)
  mwq_intercepts <- c(log(80e6), log(70e6), log(75e6))
  log_T_m <- vapply(seq_len(n_q), function(q) {
    trend <- 0.01 * q
    vapply(1:3, function(m) {
      mwq_intercepts[m] + trend + stats::rnorm(1, 0, 0.04)
    }, numeric(1))
  }, numeric(3))

  log_vol <- numeric(n_q)
  log_vol[1:4] <- log(c(220, 230, 235, 245)) + stats::rnorm(4, 0, 0.02)
  b <- c(0.3, 0.2, 0.1)
  for (q in 5:n_q) {
    yoy_dT <- log_T_m[, q] - log_T_m[, q - 4]
    log_vol[q] <- 0.0 + sum(b * yoy_dT) + 1.0 * log_vol[q - 4] +
                   stats::rnorm(1, 0, 0.02)
  }

  tibble::tibble(
    commodity          = commodity,
    quarter_end        = seq(as.Date("2015-01-01"), by = "3 months",
                              length.out = n_q) |>
                         (\(d) lubridate::ceiling_date(d, "quarter") - 1)(),
    volume_Mt          = exp(log_vol),
    tonnage_m1         = exp(log_T_m[1, ]),
    tonnage_m2         = exp(log_T_m[2, ]),
    tonnage_m3         = exp(log_T_m[3, ]),
    tonnage            = exp(log_T_m[1, ]) + exp(log_T_m[2, ]) +
                         exp(log_T_m[3, ])
  ) |>
    dplyr::mutate(
      log_volume         = log(volume_Mt),
      log_tonnage        = log(tonnage),
      log_tonnage_m1     = log(tonnage_m1),
      log_tonnage_m2     = log(tonnage_m2),
      log_tonnage_m3     = log(tonnage_m3),
      log_volume_lag4    = dplyr::lag(log_volume,     4L),
      yoy_log_tonnage    = log_tonnage    - dplyr::lag(log_tonnage,    4L),
      yoy_log_tonnage_m1 = log_tonnage_m1 - dplyr::lag(log_tonnage_m1, 4L),
      yoy_log_tonnage_m2 = log_tonnage_m2 - dplyr::lag(log_tonnage_m2, 4L),
      yoy_log_tonnage_m3 = log_tonnage_m3 - dplyr::lag(log_tonnage_m3, 4L)
    )
}

test_that("fit_bridge/midas recovers per-month coefficients", {
  feats <- simulate_features(n_q = 40)
  cfg <- list(sample = list(train_end = "2030-12-31"),
              commodities = "iron_ore",
              bridge = list(hac_lag = 1L, min_n = 12L,
                            spec = list(iron_ore = "midas")))
  fits <- fit_bridge(feats, cfg)
  expect_named(fits, "iron_ore")
  expect_equal(fits$iron_ore$diagnostics$spec, "midas")

  co <- stats::coef(fits$iron_ore$fit)
  expect_equal(unname(co[["yoy_log_tonnage_m1"]] +
                      co[["yoy_log_tonnage_m2"]] +
                      co[["yoy_log_tonnage_m3"]]), 0.6, tolerance = 0.25)
  expect_equal(co[["log_volume_lag4"]], 1.0, tolerance = 0.15)
  expect_gt(fits$iron_ore$diagnostics$r_squared, 0.5)
})

test_that("fit_bridge/aggregate picks up sum-of-monthly signal", {
  feats <- simulate_features(n_q = 40)
  cfg <- list(sample = list(train_end = "2030-12-31"),
              commodities = "iron_ore",
              bridge = list(hac_lag = 1L, min_n = 12L,
                            spec = list(iron_ore = "aggregate")))
  fits <- fit_bridge(feats, cfg)
  expect_named(fits, "iron_ore")
  expect_equal(fits$iron_ore$diagnostics$spec, "aggregate")

  co <- stats::coef(fits$iron_ore$fit)
  expect_true("yoy_log_tonnage" %in% names(co))
  # Aggregate picks up sum-of-monthly ΔT signal; coefficient should be
  # positive (not necessarily equal to DGP sum because aggregator and
  # DGP differ -- sum of logs vs log of sum).
  expect_gt(co[["yoy_log_tonnage"]], 0)
  expect_equal(co[["log_volume_lag4"]], 1.0, tolerance = 0.15)
})

test_that("fit_bridge defaults to aggregate spec when cfg missing", {
  feats <- simulate_features(n_q = 40)
  cfg <- list(sample = list(train_end = "2030-12-31"),
              commodities = "iron_ore",
              bridge = list(hac_lag = 1L, min_n = 12L))  # no spec
  fits <- fit_bridge(feats, cfg)
  expect_equal(fits$iron_ore$diagnostics$spec, "aggregate")
})

test_that("predict_bridge works for both specs", {
  feats <- simulate_features(n_q = 40)
  newdata <- feats |> utils::tail(4)
  for (s in c("aggregate", "midas")) {
    cfg <- list(sample = list(train_end = "2030-12-31"),
                commodities = "iron_ore",
                bridge = list(hac_lag = 1L, min_n = 12L,
                              spec = list(iron_ore = s)))
    fits <- fit_bridge(feats, cfg)
    preds <- predict_bridge(fits, newdata)
    expect_equal(nrow(preds), 4L, info = s)
    expect_true(all(is.finite(preds$yhat_log)), info = s)
  }
})

test_that("fit_bridge skips commodities with too few observations", {
  feats <- simulate_features(n_q = 10)
  cfg <- list(sample = list(train_end = "2030-12-31"),
              commodities = "iron_ore",
              bridge = list(hac_lag = 1L, min_n = 12L,
                            spec = list(iron_ore = "midas")))
  fits <- fit_bridge(feats, cfg)
  expect_null(fits$iron_ore)
})

test_that("fit_bridge skips commodities with degenerate regressors", {
  feats <- simulate_features(n_q = 24)
  feats$yoy_log_tonnage <- 0
  cfg <- list(sample = list(train_end = "2030-12-31"),
              commodities = "iron_ore",
              bridge = list(hac_lag = 1L, min_n = 12L,
                            spec = list(iron_ore = "aggregate")))
  fits <- fit_bridge(feats, cfg)
  expect_null(fits$iron_ore)
})
