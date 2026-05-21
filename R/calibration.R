#' Empirical coverage of the bootstrap bands on backtest quarters
#'
#' Walks the long backtest result tibble and, for each (commodity, spec)
#' that has a live fit in `bridge_fits_bench`, reconstructs the 80/95%
#' band the production code would have published *had it called this
#' quarter blind* (i.e. at `share_observed = 0`, so the residual bootstrap
#' is full-scale — the most generous version of the band). Reports
#' empirical coverage:
#'
#'   `coverage_80 = mean(actual ∈ [lower_80, upper_80])`
#'   `coverage_95 = mean(actual ∈ [lower_95, upper_95])`
#'
#' If the bands are well-calibrated, these approach 0.80 and 0.95.
#' Material gaps mean the bootstrap is mis-sized (typically: too narrow
#' because the residual draw underestimates parameter uncertainty), and
#' point at conformal-prediction recalibration as the principled fix.
#'
#' Combination specs (`equal_avg`, `inv_mse`) have no single `lm` fit to
#' draw residuals from and are left as NA here. Their point-level RMSE
#' is still in `bridge_diagnostics.csv`.
#'
#' @param backtest_aug Tibble from [augment_with_combinations()] — one
#'   row per (commodity, spec, validation quarter).
#' @param bridge_fits_bench Named list keyed by `<commodity>__<spec>`,
#'   each entry containing `$fit` (an `lm` object).
#' @param cfg Config list; uses `cfg$nowcast$bootstrap_reps` and
#'   `cfg$nowcast$seed`.
#' @return Tibble keyed by `(commodity, spec)` with `n_oos`,
#'   `coverage_80`, `coverage_95`.
#' @export
backtest_coverage <- function(backtest_aug, bridge_fits_bench, cfg) {
  empty <- tibble::tibble(
    commodity   = character(),
    spec        = character(),
    n_oos       = integer(),
    coverage_80 = double(),
    coverage_95 = double()
  )
  if (nrow(backtest_aug) == 0L || length(bridge_fits_bench) == 0L) {
    return(empty)
  }

  B    <- cfg$nowcast$bootstrap_reps %||% 1000
  seed <- cfg$nowcast$seed %||% 20260419

  # Same residual-bootstrap recipe as run_nowcast, but at share = 0
  # (i.e. full residual scale, no in-quarter shrink) so we're testing
  # the bands as published at the *start* of the validation quarter.
  cov_for_row <- function(point_estimate, residuals, actual) {
    if (!is.finite(point_estimate) || !is.finite(actual) ||
        length(residuals) < 2L) {
      return(list(in_80 = NA, in_95 = NA))
    }
    point_log <- log(point_estimate)
    draws <- exp(point_log +
                 sample(residuals, B, replace = TRUE))
    q80 <- stats::quantile(draws, c(0.10, 0.90), names = FALSE)
    q95 <- stats::quantile(draws, c(0.025, 0.975), names = FALSE)
    list(
      in_80 = actual >= q80[1] && actual <= q80[2],
      in_95 = actual >= q95[1] && actual <= q95[2]
    )
  }

  set.seed(seed)
  rows <- backtest_aug |>
    dplyr::filter(!is.na(.data$point_estimate), !is.na(.data$actual))

  if (nrow(rows) == 0L) return(empty)

  rows$in_80 <- NA
  rows$in_95 <- NA
  for (i in seq_len(nrow(rows))) {
    key <- paste0(rows$commodity[i], "__", rows$spec[i])
    fit_entry <- bridge_fits_bench[[key]]
    if (is.null(fit_entry) || is.null(fit_entry$fit)) next
    resids <- as.numeric(fit_entry$fit$residuals)
    res <- cov_for_row(rows$point_estimate[i], resids, rows$actual[i])
    rows$in_80[i] <- res$in_80
    rows$in_95[i] <- res$in_95
  }

  rows |>
    dplyr::group_by(.data$commodity, .data$spec) |>
    dplyr::summarise(
      n_oos       = sum(!is.na(.data$in_80)),
      coverage_80 = if (sum(!is.na(.data$in_80)) > 0L) {
                      mean(.data$in_80, na.rm = TRUE)
                    } else NA_real_,
      coverage_95 = if (sum(!is.na(.data$in_95)) > 0L) {
                      mean(.data$in_95, na.rm = TRUE)
                    } else NA_real_,
      .groups     = "drop"
    )
}
