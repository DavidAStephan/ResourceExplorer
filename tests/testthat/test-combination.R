## Forecast combination, candidate-bench, and OOS-R^2 tests.

# Reuse the synthetic feature panel from test-backtest.R via source().
# Note testthat sources every test file fresh, so `simulate_feature_panel`
# is defined here too to keep the file standalone.
.mk_features <- function(n_q = 40, commodity = "iron_ore", seed = 42) {
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
    log_vol[q] <- sum(b * yoy_dT) + 1.0 * log_vol[q - 4] +
                   stats::rnorm(1, 0, 0.02)
  }
  tibble::tibble(
    commodity = commodity,
    quarter_end = seq(as.Date("2015-01-01"), by = "3 months",
                       length.out = n_q) |>
                  (\(d) lubridate::ceiling_date(d, "quarter") - 1)(),
    volume_Mt = exp(log_vol),
    tonnage_m1 = exp(log_T_m[1, ]),
    tonnage_m2 = exp(log_T_m[2, ]),
    tonnage_m3 = exp(log_T_m[3, ]),
    tonnage    = exp(log_T_m[1, ]) + exp(log_T_m[2, ]) + exp(log_T_m[3, ]),
    log_volume = log_vol,
    log_tonnage    = log(exp(log_T_m[1, ]) + exp(log_T_m[2, ]) +
                          exp(log_T_m[3, ])),
    log_tonnage_m1 = log_T_m[1, ],
    log_tonnage_m2 = log_T_m[2, ],
    log_tonnage_m3 = log_T_m[3, ],
    log_volume_lag4 = dplyr::lag(log_vol, 4L)
  ) |>
  dplyr::mutate(
    yoy_log_volume     = log_volume     - dplyr::lag(log_volume,     4L),
    yoy_log_tonnage    = log_tonnage    - dplyr::lag(log_tonnage,    4L),
    yoy_log_tonnage_m1 = log_tonnage_m1 - dplyr::lag(log_tonnage_m1, 4L),
    yoy_log_tonnage_m2 = log_tonnage_m2 - dplyr::lag(log_tonnage_m2, 4L),
    yoy_log_tonnage_m3 = log_tonnage_m3 - dplyr::lag(log_tonnage_m3, 4L)
  )
}

.cfg_bench <- function(commodities = "iron_ore") {
  list(
    sample      = list(train_end = "2030-12-31", valid_start = "2020-01-01"),
    commodities = commodities,
    bridge      = list(hac_lag = 1L, min_n = 12L,
                       candidates = c("aggregate", "midas", "bojo"))
  )
}

test_that("fit_bridge_bench returns one fit per (commodity, spec)", {
  feats <- .mk_features()
  fits  <- fit_bridge_bench(feats, .cfg_bench())
  expect_setequal(names(fits),
                  c("iron_ore__aggregate", "iron_ore__midas",
                    "iron_ore__bojo"))
  # Each fit carries the diagnostics tibble + train_data for combination.
  for (f in fits) {
    expect_true(is.list(f))
    expect_true(!is.null(f$diagnostics))
    expect_true(!is.null(f$train_data))
  }
})

test_that("bojo spec is algebraically equivalent to imposing beta_lag4 = 1", {
  # Build a tiny feature panel where the DGP has beta_lag4 = 1 exactly,
  # so the aggregate and bojo fits should agree on beta_T.
  feats <- .mk_features()
  cfg <- .cfg_bench()
  fits <- fit_bridge_bench(feats, cfg)
  agg <- fits[["iron_ore__aggregate"]]
  boj <- fits[["iron_ore__bojo"]]
  expect_equal(unname(stats::coef(agg$fit)["log_volume_lag4"]), 1,
               tolerance = 0.05)
  expect_equal(
    unname(stats::coef(agg$fit)["yoy_log_tonnage"]),
    unname(stats::coef(boj$fit)["yoy_log_tonnage"]),
    tolerance = 0.05
  )
})

test_that("Wald p-value for beta_lag4 = 1 is NA on bojo and finite elsewhere", {
  feats <- .mk_features()
  fits <- fit_bridge_bench(feats, .cfg_bench())
  agg_p <- fits[["iron_ore__aggregate"]]$diagnostics$beta_lag4_eq_1_pval
  mid_p <- fits[["iron_ore__midas"]]$diagnostics$beta_lag4_eq_1_pval
  boj_p <- fits[["iron_ore__bojo"]]$diagnostics$beta_lag4_eq_1_pval
  expect_true(is.finite(agg_p))
  expect_true(is.finite(mid_p))
  expect_true(is.na(boj_p))
})

test_that("augment_with_combinations adds equal_avg + inv_mse rows per quarter", {
  feats <- .mk_features()
  cfg   <- .cfg_bench()
  cfg$sample$valid_start <- "2020-01-01"
  bt    <- backtest_rmse(feats, cfg)
  expect_true(nrow(bt) > 0)
  aug   <- augment_with_combinations(bt)
  expect_true(all(c("equal_avg", "inv_mse") %in% unique(aug$spec)))
  # For each commodity x quarter where any spec produced a forecast,
  # equal_avg should equal the unweighted mean of the candidate forecasts.
  for (q in unique(aug$quarter_end)) {
    comp <- dplyr::filter(bt, .data$quarter_end == q,
                          !is.na(.data$point_estimate))
    if (nrow(comp) == 0L) next
    expected <- mean(comp$point_estimate)
    got <- dplyr::filter(aug, .data$quarter_end == q,
                         .data$spec == "equal_avg")$point_estimate
    expect_equal(got, expected, tolerance = 1e-9)
  }
})

test_that("oos_diagnostics computes RMSE / ratio / R^2_oos consistently", {
  feats <- .mk_features()
  cfg   <- .cfg_bench()
  cfg$sample$valid_start <- "2020-01-01"
  bt    <- backtest_rmse(feats, cfg)
  aug   <- augment_with_combinations(bt)
  oos   <- oos_diagnostics(aug)
  expect_true(all(oos$rmse_valid >= 0))
  expect_true(all(oos$ratio_vs_naive >= 0))
  # R^2_oos should be <= 1; can be negative if a model underperforms
  # the mean baseline. Just check finiteness.
  expect_true(all(is.finite(oos$r_squared_oos)))
})

test_that("production_choice picks the lowest-RMSE row per commodity", {
  fake_oos <- tibble::tibble(
    commodity      = rep("iron_ore", 4),
    spec           = c("aggregate", "midas", "bojo", "equal_avg"),
    rmse_valid     = c(5.0, 4.5, 4.0, 4.3),
    rmse_naive     = 6,
    ratio_vs_naive = c(5.0, 4.5, 4.0, 4.3) / 6,
    r_squared_oos  = c(0.7, 0.75, 0.8, 0.78)
  )
  choice <- production_choice(fake_oos)
  expect_equal(choice$production_spec, "bojo")
})

test_that("select_production_models returns single-spec bundles when one spec wins", {
  feats <- .mk_features()
  cfg   <- .cfg_bench()
  cfg$sample$valid_start <- "2020-01-01"
  fits  <- fit_bridge_bench(feats, cfg)
  bt    <- backtest_rmse(feats, cfg)
  aug   <- augment_with_combinations(bt)
  oos   <- oos_diagnostics(aug)
  ch    <- production_choice(oos)
  pm    <- select_production_models(fits, oos, ch, cfg)
  expect_named(pm, "iron_ore")
  expect_equal(sum(pm$iron_ore$weights), 1, tolerance = 1e-9)
  # Weights are non-negative.
  expect_true(all(pm$iron_ore$weights >= 0))
})
