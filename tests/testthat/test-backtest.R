## Backtest tests (MIDAS spec).

simulate_feature_panel <- function(n_per_com = 40,
                                   commodities = c("iron_ore","coal")) {
  purrr::map_dfr(commodities, function(com) {
    set.seed(match(com, commodities))
    n_q <- n_per_com
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
      log_vol[q] <- sum(b * yoy_dT) + 1.0 * log_vol[q - 4] +
                     stats::rnorm(1, 0, 0.02)
    }
    tibble::tibble(
      commodity          = com,
      quarter_end        = seq(as.Date("2015-01-01"), by = "3 months",
                                length.out = n_q) |>
                            (\(d) lubridate::ceiling_date(d, "quarter") - 1)(),
      volume_Mt          = exp(log_vol),
      tonnage_m1         = exp(log_T_m[1, ]),
      tonnage_m2         = exp(log_T_m[2, ]),
      tonnage_m3         = exp(log_T_m[3, ]),
      tonnage            = exp(log_T_m[1, ]) + exp(log_T_m[2, ]) +
                            exp(log_T_m[3, ]),
      log_volume         = log_vol,
      log_tonnage        = log(exp(log_T_m[1, ]) + exp(log_T_m[2, ]) +
                                exp(log_T_m[3, ])),
      log_tonnage_m1     = log_T_m[1, ],
      log_tonnage_m2     = log_T_m[2, ],
      log_tonnage_m3     = log_T_m[3, ],
      log_volume_lag4    = dplyr::lag(log_vol, 4L)
    ) |>
    dplyr::mutate(
      yoy_log_volume     = log_volume      - dplyr::lag(log_volume,      4L),
      yoy_log_tonnage    = log_tonnage     - dplyr::lag(log_tonnage,     4L),
      yoy_log_tonnage_m1 = log_tonnage_m1  - dplyr::lag(log_tonnage_m1,  4L),
      yoy_log_tonnage_m2 = log_tonnage_m2  - dplyr::lag(log_tonnage_m2,  4L),
      yoy_log_tonnage_m3 = log_tonnage_m3  - dplyr::lag(log_tonnage_m3,  4L)
    )
  })
}

test_that("backtest_rmse returns one row per commodity x spec x quarter", {
  feats <- simulate_feature_panel(n_per_com = 40)
  cfg <- list(
    sample      = list(train_end = "2020-12-31", valid_start = "2021-01-01"),
    commodities = c("iron_ore","coal"),
    bridge      = list(hac_lag = 1L, min_n = 12L,
                       candidates = c("aggregate", "midas", "bojo"))
  )
  out <- backtest_rmse(feats, cfg)
  expect_named(out, c("commodity","spec","quarter_end","actual","point_estimate",
                      "naive_srw","err","err_naive"))
  expect_true(nrow(out) > 0L)
  expect_setequal(unique(out$commodity), cfg$commodities)
  expect_setequal(unique(out$spec), cfg$bridge$candidates)
})

test_that("backtest_rmse returns empty tibble when no valid quarters", {
  feats <- simulate_feature_panel(n_per_com = 10)
  cfg <- list(
    sample      = list(train_end = "2020-12-31", valid_start = "2030-01-01"),
    commodities = c("iron_ore"),
    bridge      = list(hac_lag = 1L, min_n = 12L)
  )
  out <- backtest_rmse(feats, cfg)
  expect_equal(nrow(out), 0L)
})
