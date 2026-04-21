#' Newey-West HAC variance-covariance matrix
#'
#' Heteroscedasticity- and autocorrelation-consistent (HAC) covariance
#' matrix with Bartlett kernel. Hand-rolled replacement for
#' `sandwich::NeweyWest()` because `{sandwich}` is not on the work-laptop
#' package allow-list.
#'
#' Formula (no pre-whitening):
#'
#' \deqn{V_{HAC} = n (X'X)^{-1} \Omega (X'X)^{-1}}
#'
#' with
#' \deqn{\Omega = \Gamma_0 + \sum_{h=1}^{L} w_h (\Gamma_h + \Gamma_h')}
#' \deqn{w_h = 1 - h / (L+1), \qquad \Gamma_h = \tfrac{1}{n} \sum_{t=h+1}^{n} u_t u'_{t-h}}
#'
#' where \eqn{u_t = x_t e_t} is the per-observation score for OLS. This
#' matches `sandwich::NeweyWest(fit, lag = L, prewhite = FALSE)` to
#' machine precision (see `tests/testthat/test-hac.R`).
#'
#' @param fit An `lm` object.
#' @param lag Non-negative integer bandwidth \eqn{L}. `lag = 0` returns
#'   the heteroscedasticity-consistent (White) covariance.
#' @param prewhite Must be `FALSE` (pre-whitening not implemented; we
#'   don't need it for our bridge regressions).
#' @return A k-by-k numeric matrix with the regressor names as dimnames.
#' @export
nw_vcov <- function(fit, lag = 3L, prewhite = FALSE) {
  if (!inherits(fit, "lm")) stop("nw_vcov: fit must be an lm object", call. = FALSE)
  if (isTRUE(prewhite))    stop("nw_vcov: prewhite = TRUE not implemented", call. = FALSE)
  if (!is.numeric(lag) || length(lag) != 1L || lag < 0 || lag != as.integer(lag)) {
    stop("nw_vcov: lag must be a non-negative integer", call. = FALSE)
  }
  lag <- as.integer(lag)

  X <- stats::model.matrix(fit)
  e <- as.numeric(stats::residuals(fit))
  n <- length(e)
  if (n <= lag + 1L) {
    stop(sprintf("nw_vcov: need n > lag+1 observations (n=%d, lag=%d)", n, lag),
         call. = FALSE)
  }
  u <- X * e  # n x k; each row is x_t * e_t

  S <- crossprod(u) / n  # Gamma_0
  for (h in seq_len(lag)) {
    w  <- 1 - h / (lag + 1L)
    Gh <- crossprod(u[(h + 1L):n, , drop = FALSE],
                    u[1L:(n - h), , drop = FALSE]) / n
    S  <- S + w * (Gh + t(Gh))
  }

  XpX_inv <- solve(crossprod(X))
  V <- n * XpX_inv %*% S %*% XpX_inv
  nm <- colnames(X)
  dimnames(V) <- list(nm, nm)
  V
}
