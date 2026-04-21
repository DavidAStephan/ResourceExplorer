## Nowcast tests (MIDAS spec).

simulate_fits_per_commodity <- function(commodities = c("iron_ore","coal"),
                                        n_q = 40, seed = 20260419) {
  feats <- purrr::map_dfr(commodities, function(com) {
    set.seed(match(com, commodities))
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
      yoy_log_tonnage    = log_tonnage    - dplyr::lag(log_tonnage,    4L),
      yoy_log_tonnage_m1 = log_tonnage_m1 - dplyr::lag(log_tonnage_m1, 4L),
      yoy_log_tonnage_m2 = log_tonnage_m2 - dplyr::lag(log_tonnage_m2, 4L),
      yoy_log_tonnage_m3 = log_tonnage_m3 - dplyr::lag(log_tonnage_m3, 4L)
    )
  })

  cfg <- list(
    sample      = list(train_end = "2030-12-31", valid_start = "2031-01-01"),
    commodities = commodities,
    bridge      = list(hac_lag = 1L, min_n = 12L,
                       spec = list(iron_ore = "midas",
                                    coal     = "aggregate")),
    nowcast     = list(bootstrap_reps = 50, seed = seed)
  )
  fits <- fit_bridge(feats, cfg)
  list(features = feats, fits = fits, cfg = cfg)
}

simulate_portwatch <- function(commodities, last_date = Sys.Date()) {
  purrr::map_dfr(commodities, function(com) {
    tibble::tibble(
      obs_date     = seq(as.Date("2023-01-01"), last_date, by = "day"),
      port_id      = "port_sim",
      commodity    = com,
      tonnage      = abs(stats::rnorm(length(seq(as.Date("2023-01-01"),
                                                 last_date, by="day")),
                                       1e6, 1e5)),
      vessel_count = 5L,
      ingested_at  = Sys.time()
    )
  })
}

test_that("run_nowcast returns one row per commodity with the full schema", {
  s <- simulate_fits_per_commodity()
  as_of <- max(s$features$quarter_end) + 40
  pw <- simulate_portwatch(s$cfg$commodities, last_date = as_of)
  out <- run_nowcast(s$fits, s$features, s$cfg,
                     portwatch = pw, ports_meta = NULL,
                     as_of = as_of)
  expect_equal(nrow(out), length(s$cfg$commodities))
  expect_setequal(out$commodity, s$cfg$commodities)
  expect_named(out, c("commodity", "quarter_end",
                      "point_estimate_Mt",
                      "lower_80", "upper_80", "lower_95", "upper_95",
                      "share_observed", "run_timestamp"))
})

test_that("empty fit list returns NA nowcasts per commodity", {
  s <- simulate_fits_per_commodity()
  as_of <- max(s$features$quarter_end) + 40
  pw <- simulate_portwatch(s$cfg$commodities, last_date = as_of)
  out <- run_nowcast(list(), s$features, s$cfg,
                     portwatch = pw, ports_meta = NULL,
                     as_of = as_of)
  expect_equal(nrow(out), length(s$cfg$commodities))
  expect_true(all(is.na(out$point_estimate_Mt)))
})
