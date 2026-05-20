#' Fit per-commodity bridge regressions (candidate-bench version)
#'
#' Each commodity is fit under several candidate specifications. The
#' production nowcast either picks the single best by out-of-sample
#' RMSE or averages across candidates (see `R/combination.R` +
#' [select_production_models()]). Backtest does the model-selection
#' work; this function just fits each candidate against the available
#' training data.
#'
#' Supported specs:
#'
#' - **aggregate** (3 params + intercept), the parsimonious variant:
#'   \deqn{\log V_{c,Q} = \beta_0 + \beta_T \, \Delta_{Q,Q-4}\log T_{c,Q}
#'                       + \beta_4 \log V_{c,Q-4} + \varepsilon_{c,Q}}
#'
#' - **midas** (5 params + intercept), the unrestricted-MIDAS variant:
#'   \deqn{\log V_{c,Q} = \beta_0 + \sum_{m=1}^{3} \beta_m \,
#'                         \Delta_{Q,Q-4}\log T_{c,Q,m}
#'                       + \beta_4 \log V_{c,Q-4} + \varepsilon_{c,Q}}
#'
#' - **bojo** (2 params, after Furukawa & Hisano 2022 / Del-Rosario &
#'   Quach 2024), the pure YoY-on-YoY form. Algebraically equivalent
#'   to the `aggregate` spec with `beta_4` constrained to 1:
#'   \deqn{\Delta_{Q,Q-4}\log V_{c,Q} = \beta_0
#'                         + \beta_T \, \Delta_{Q,Q-4}\log T_{c,Q}
#'                         + \varepsilon_{c,Q}}
#'
#' Each fit reports the same diagnostics tibble plus a `beta_lag4_eq_1_pval`
#' from a Wald test (NA for the `bojo` spec, where the restriction is
#' imposed by construction).
#'
#' @param features Quarterly feature tibble from [build_features()].
#' @param cfg Config list. Uses `cfg$sample$train_end`, `cfg$commodities`,
#'   `cfg$bridge$hac_lag`, `cfg$bridge$min_n`, and the candidate list
#'   `cfg$bridge$candidates` (default: `c("aggregate", "midas", "bojo")`).
#' @return Long named list keyed by `"<commodity>__<spec>"`. Each element
#'   is a list with `fit`, `vcov_hac`, `residuals`, `spec`, `commodity`,
#'   and `diagnostics`.
#' @export
fit_bridge_bench <- function(features, cfg) {
  train_end   <- as.Date(cfg$sample$train_end %||% "2023-12-31")
  commodities <- cfg$commodities %||% unique(features$commodity)
  candidates  <- cfg$bridge$candidates %||% c("aggregate", "midas", "bojo")
  hac_lag     <- as.integer(cfg$bridge$hac_lag %||% 1L)
  min_n       <- as.integer(cfg$bridge$min_n   %||% 12L)

  out <- list()
  for (com in commodities) {
    for (spec in candidates) {
      key <- paste0(com, "__", spec)
      out[[key]] <- fit_bridge_one(features, cfg, com, spec,
                                    train_end, hac_lag, min_n)
    }
  }
  out
}

#' Back-compat single-spec wrapper kept so any external caller using
#' `cfg$bridge$spec[[c]]` still works. Returns the one-spec-per-commodity
#' list with the shape the old code expected.
#' @param features Quarterly feature tibble.
#' @param cfg Config list with `cfg$bridge$spec[[commodity]] = "aggregate" | "midas" | "bojo"`.
#' @return Named list keyed by commodity (same shape as the pre-bench
#'   `fit_bridge` output).
#' @export
fit_bridge <- function(features, cfg) {
  train_end   <- as.Date(cfg$sample$train_end %||% "2023-12-31")
  commodities <- cfg$commodities %||% unique(features$commodity)
  spec_map    <- cfg$bridge$spec %||% list()
  hac_lag     <- as.integer(cfg$bridge$hac_lag %||% 1L)
  min_n       <- as.integer(cfg$bridge$min_n   %||% 12L)

  fits <- stats::setNames(vector("list", length(commodities)), commodities)
  for (com in commodities) {
    spec <- tolower(spec_map[[com]] %||% "aggregate")
    fits[[com]] <- fit_bridge_one(features, cfg, com, spec,
                                   train_end, hac_lag, min_n)
  }
  fits
}

#' Fit a single (commodity, spec) bridge. Returns NULL on any
#' degeneracy (too few obs, near-zero variance regressor, HAC failure).
#' @keywords internal
fit_bridge_one <- function(features, cfg, com, spec,
                            train_end, hac_lag, min_n) {
  spec <- tolower(spec)
  info <- spec_info(spec)
  if (is.null(info)) {
    log_warn("fit_bridge[%s/%s]: unknown spec -- skipping", com, spec)
    return(NULL)
  }

  required_cols <- c(info$lhs, info$rhs, info$predict_extra)
  dat <- features |>
    dplyr::filter(.data$commodity == com,
                  .data$quarter_end <= train_end) |>
    dplyr::arrange(.data$quarter_end)
  dat <- dat[stats::complete.cases(dat[, required_cols, drop = FALSE]),
             , drop = FALSE]

  if (nrow(dat) < min_n) {
    log_warn("fit_bridge[%s/%s]: %d obs < min_n=%d -- skipping",
             com, spec, nrow(dat), min_n)
    return(NULL)
  }
  vs <- vapply(c(info$lhs, info$rhs),
               function(v) stats::sd(dat[[v]], na.rm = TRUE),
               numeric(1))
  if (any(vs < 1e-8, na.rm = TRUE) || any(is.na(vs))) {
    log_warn("fit_bridge[%s/%s]: degenerate regressor (sd<1e-8) -- skipping",
             com, spec)
    return(NULL)
  }

  formula_fit <- stats::as.formula(
    paste(info$lhs, "~", paste(info$rhs, collapse = " + "))
  )
  fit <- stats::lm(formula_fit, data = dat)
  vcov_hac <- tryCatch(
    nw_vcov(fit, lag = hac_lag, prewhite = FALSE),
    error = function(e) {
      log_warn("fit_bridge[%s/%s]: nw_vcov failed (%s) -- skipping",
               com, spec, conditionMessage(e))
      NULL
    }
  )
  if (is.null(vcov_hac)) return(NULL)

  diag <- one_spec_diagnostics(fit, vcov_hac, dat, com, spec)
  log_bridge_fit(com, spec, diag)
  if (is.finite(diag$chow_pval) && diag$chow_pval < 0.05) {
    log_warn("fit_bridge[%s/%s]: structural-break Chow F=%.2f p=%.3f (break at %s)",
             com, spec, diag$chow_fstat, diag$chow_pval,
             format(diag$chow_break_at, "%Y-%m-%d"))
  }

  list(
    fit         = fit,
    vcov_hac    = vcov_hac,
    residuals   = stats::residuals(fit),
    spec        = spec,
    commodity   = com,
    diagnostics = diag,
    # Stored so combination logic can reconstruct in-sample log V hat
    # for the `bojo` spec (which fits Δ_4 log V on the lm side and
    # needs `log_volume_lag4` from the training frame for back-transform).
    train_data  = dat
  )
}

#' Spec metadata: lhs / rhs columns + how to invert `predict(fit)` back
#' to log_volume_Mt-space. For the `bojo` spec, the lm fits Δ_4 log V on
#' Δ_4 log T, so the back-transform adds `log_volume_lag4` from the
#' prediction row to recover the same scale as the other specs.
#'
#' Returning NULL signals "unknown spec".
#' @keywords internal
spec_info <- function(spec) {
  switch(
    tolower(spec),
    aggregate = list(
      lhs = "log_volume",
      rhs = c("yoy_log_tonnage", "log_volume_lag4"),
      predict_extra = character(),
      to_log_volume = function(yhat, pred_row) yhat
    ),
    midas = list(
      lhs = "log_volume",
      rhs = c("yoy_log_tonnage_m1", "yoy_log_tonnage_m2",
              "yoy_log_tonnage_m3", "log_volume_lag4"),
      predict_extra = character(),
      to_log_volume = function(yhat, pred_row) yhat
    ),
    bojo = list(
      lhs = "yoy_log_volume",
      rhs = "yoy_log_tonnage",
      # bojo's lm doesn't see log_volume_lag4, but we need it at
      # prediction time to invert from YoY-Δ space back to log space.
      predict_extra = "log_volume_lag4",
      to_log_volume = function(yhat, pred_row) yhat + pred_row$log_volume_lag4
    ),
    lagged = list(
      # Aggregate spec augmented with a 1-quarter-lagged YoY tonnage
      # term. Tests the Adland-Jia-Strandenes (2017) hypothesis that
      # AIS leads customs-cleared trade by several weeks.
      lhs = "log_volume",
      rhs = c("yoy_log_tonnage", "yoy_log_tonnage_lag1", "log_volume_lag4"),
      predict_extra = character(),
      to_log_volume = function(yhat, pred_row) yhat
    ),
    NULL
  )
}

#' Build the per-spec diagnostics row. Includes the Wald test of
#' beta_lag4 = 1 (`beta_lag4_eq_1_pval`) when `log_volume_lag4` is in the
#' RHS; NA for `bojo` where the restriction is imposed.
#' @keywords internal
one_spec_diagnostics <- function(fit, vcov_hac, dat, com, spec) {
  co <- stats::coef(fit)
  res <- stats::residuals(fit)

  beta_T <- NA_real_; beta_T_se <- NA_real_
  beta_m1 <- beta_m2 <- beta_m3 <- NA_real_
  beta_lag4 <- NA_real_; beta_lag4_eq_1_pval <- NA_real_

  if (spec == "midas") {
    idx <- c("yoy_log_tonnage_m1", "yoy_log_tonnage_m2",
             "yoy_log_tonnage_m3")
    beta_T    <- sum(co[idx])
    beta_T_se <- sqrt(max(sum(vcov_hac[idx, idx]), 0))
    beta_m1 <- unname(co["yoy_log_tonnage_m1"])
    beta_m2 <- unname(co["yoy_log_tonnage_m2"])
    beta_m3 <- unname(co["yoy_log_tonnage_m3"])
  } else {
    beta_T    <- unname(co["yoy_log_tonnage"])
    beta_T_se <- sqrt(max(vcov_hac["yoy_log_tonnage",
                                    "yoy_log_tonnage"], 0))
  }

  if ("log_volume_lag4" %in% names(co)) {
    beta_lag4 <- unname(co["log_volume_lag4"])
    # Wald test of H0: beta_lag4 = 1 using the HAC vcov.
    v <- vcov_hac["log_volume_lag4", "log_volume_lag4"]
    if (is.finite(v) && v > 0) {
      z <- (beta_lag4 - 1) / sqrt(v)
      beta_lag4_eq_1_pval <- 2 * stats::pnorm(-abs(z))
    }
  }

  chow <- chow_test_midpoint(fit, dat)

  tibble::tibble(
    commodity            = com,
    spec                 = spec,
    n_obs                = nrow(dat),
    r_squared            = summary(fit)$r.squared,
    rmse_train           = sqrt(mean(res^2)),
    dw_stat              = durbin_watson(res),
    beta_tonnage         = beta_T,
    beta_tonnage_se      = beta_T_se,
    beta_lag4            = beta_lag4,
    beta_lag4_eq_1_pval  = beta_lag4_eq_1_pval,
    beta_m1              = beta_m1,
    beta_m2              = beta_m2,
    beta_m3              = beta_m3,
    chow_fstat           = chow$fstat,
    chow_pval            = chow$pval,
    chow_break_at        = chow$break_at
  )
}

#' @keywords internal
log_bridge_fit <- function(com, spec, diag) {
  if (spec == "midas") {
    log_info(
      "fit_bridge[%s/midas]: n=%d R^2=%.3f RMSE=%.3f betaT=%.3f lag4=%.3f (m1=%.2f m2=%.2f m3=%.2f)",
      com, diag$n_obs, diag$r_squared, diag$rmse_train,
      diag$beta_tonnage, diag$beta_lag4,
      diag$beta_m1, diag$beta_m2, diag$beta_m3
    )
  } else if (spec == "bojo") {
    log_info(
      "fit_bridge[%s/bojo]: n=%d R^2=%.3f RMSE=%.3f betaT=%.3f (lag4 forced to 1)",
      com, diag$n_obs, diag$r_squared, diag$rmse_train, diag$beta_tonnage
    )
  } else {
    log_info(
      "fit_bridge[%s/aggregate]: n=%d R^2=%.3f RMSE=%.3f betaT=%.3f lag4=%.3f",
      com, diag$n_obs, diag$r_squared, diag$rmse_train,
      diag$beta_tonnage, diag$beta_lag4
    )
  }
}

#' Predict log V_Q from a single fit object regardless of spec.
#'
#' Handles the bojo back-transform: when the lm fitted Δ_4 log V on
#' Δ_4 log T, `predict()` returns the YoY-Δ scale; we add
#' `log_volume_lag4` from the prediction row to recover log_volume.
#'
#' @param fits Named list of fit objects (output of [fit_bridge()] or
#'   [fit_bridge_bench()]).
#' @param newdata Long feature tibble for the horizon to predict.
#' @return Tibble: `quarter_end`, `commodity`, `yhat_log`, `yhat_volume_Mt`.
#' @export
predict_bridge <- function(fits, newdata) {
  out <- list()
  for (key in names(fits)) {
    entry <- fits[[key]]
    if (is.null(entry)) next
    com  <- entry$commodity %||% key
    spec <- entry$spec      %||% "aggregate"

    dat <- newdata |>
      dplyr::filter(.data$commodity == com) |>
      dplyr::arrange(.data$quarter_end)
    if (nrow(dat) == 0) next

    yhat_raw <- as.numeric(stats::predict(entry$fit, newdata = dat))
    info <- spec_info(spec)
    yhat_log <- vapply(seq_along(yhat_raw), function(i) {
      info$to_log_volume(yhat_raw[i], dat[i, , drop = FALSE])
    }, numeric(1))

    out[[key]] <- tibble::tibble(
      quarter_end    = dat$quarter_end,
      commodity      = com,
      spec           = spec,
      yhat_log       = yhat_log,
      yhat_volume_Mt = exp(yhat_log)
    )
  }
  dplyr::bind_rows(out)
}

#' Durbin-Watson stat for a residual vector (no regression required).
#' Values near 2 suggest no first-order autocorrelation; < 1 or > 3 is a red flag.
#' @keywords internal
durbin_watson <- function(res) {
  d <- diff(res)
  sum(d * d) / sum(res * res)
}
