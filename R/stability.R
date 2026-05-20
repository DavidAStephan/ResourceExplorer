#' Chow test for a structural break at the midpoint of the training sample
#'
#' Splits the training data in half (by `quarter_end` order), refits the
#' same lm on each half, and reports the standard Chow F-stat for the
#' null "no break".
#'
#' \deqn{F = \frac{(SSR_{pooled} - SSR_1 - SSR_2)/k}{(SSR_1 + SSR_2)/(n - 2k)}}
#'
#' Returns NA when either half is below `min_n` observations -- we want
#' an honest test, not one fit on 6 points.
#'
#' Built-in base R so we don't pick up an external dependency
#' (`strucchange`, `lmtest`) for one test. The Chow setup is the right
#' choice anyway at our sample size: a single known break at the
#' midpoint is the highest-power test you can run with N ≈ 23.
#'
#' @param fit `lm` object from [fit_bridge_one()].
#' @param data Training tibble used to fit `fit`.
#' @param min_n_per_half Minimum observations per half-sample.
#' @return List with `fstat`, `pval`, `df1`, `df2`, `n`, `break_at`.
#' @keywords internal
chow_test_midpoint <- function(fit, data, min_n_per_half = 8L) {
  empty <- list(fstat = NA_real_, pval = NA_real_,
                df1 = NA_integer_, df2 = NA_integer_,
                n = NA_integer_, break_at = as.Date(NA))
  if (is.null(fit) || is.null(data) || nrow(data) < 2L * min_n_per_half) {
    return(empty)
  }
  data <- data[order(data$quarter_end), , drop = FALSE]
  n <- nrow(data)
  mid <- floor(n / 2)
  if (mid < min_n_per_half || (n - mid) < min_n_per_half) return(empty)

  form <- stats::formula(fit)
  fit1 <- tryCatch(stats::lm(form, data = data[seq_len(mid), , drop = FALSE]),
                   error = function(e) NULL)
  fit2 <- tryCatch(stats::lm(form, data = data[(mid + 1L):n, , drop = FALSE]),
                   error = function(e) NULL)
  if (is.null(fit1) || is.null(fit2)) return(empty)

  ssr_p <- sum(stats::residuals(fit)^2)
  ssr_1 <- sum(stats::residuals(fit1)^2)
  ssr_2 <- sum(stats::residuals(fit2)^2)
  k <- length(stats::coef(fit))

  df1 <- k
  df2 <- n - 2L * k
  if (df2 <= 0) return(empty)

  fstat <- ((ssr_p - ssr_1 - ssr_2) / df1) /
           ((ssr_1 + ssr_2) / df2)
  if (!is.finite(fstat) || fstat < 0) return(empty)

  list(
    fstat    = fstat,
    pval     = stats::pf(fstat, df1, df2, lower.tail = FALSE),
    df1      = df1,
    df2      = df2,
    n        = n,
    break_at = data$quarter_end[mid]
  )
}
