## Newey-West HAC unit tests.
##
## Because `sandwich` is not on the work-laptop allow-list, we can't
## depend on it for parity. Instead, we check against a hand-computed
## Bartlett-weighted long-run variance on a tiny fixture, and sanity
## properties (symmetry, lag=0 special case) that pin down correctness.

test_that("nw_vcov with lag=0 equals White-style (X'X)^-1 X'ee'X (X'X)^-1", {
  set.seed(1)
  n <- 40
  x <- rnorm(n)
  y <- 1 + 0.5 * x + rnorm(n, sd = 0.3)
  fit <- stats::lm(y ~ x)

  V_nw <- nw_vcov(fit, lag = 0L)

  X <- stats::model.matrix(fit)
  e <- as.numeric(stats::residuals(fit))
  u <- X * e
  S <- crossprod(u) / n
  XpX_inv <- solve(crossprod(X))
  V_ref <- n * XpX_inv %*% S %*% XpX_inv

  expect_lt(max(abs(V_nw - V_ref)), 1e-12)
})

test_that("nw_vcov result is symmetric and square", {
  set.seed(2)
  n <- 60
  x <- rnorm(n); z <- rnorm(n)
  y <- 2 + 0.3 * x - 0.2 * z + rnorm(n, sd = 0.2)
  fit <- stats::lm(y ~ x + z)
  V <- nw_vcov(fit, lag = 4L)
  expect_equal(dim(V), c(3L, 3L))
  expect_lt(max(abs(V - t(V))), 1e-14)
})

test_that("nw_vcov with lag=3 matches a manual Bartlett long-run variance", {
  set.seed(3)
  n <- 50
  x <- rnorm(n)
  y <- 0.1 + 0.7 * x + as.numeric(stats::filter(rnorm(n, sd = 0.2),
                                                0.5, "recursive"))
  fit <- stats::lm(y ~ x)

  V_nw <- nw_vcov(fit, lag = 3L)

  # Hand-roll the same Bartlett-weighted formula
  X <- stats::model.matrix(fit)
  e <- as.numeric(stats::residuals(fit))
  u <- X * e
  k <- ncol(X)
  S <- crossprod(u) / n
  L <- 3L
  for (h in seq_len(L)) {
    w  <- 1 - h / (L + 1)
    Gh <- crossprod(u[(h + 1L):n, , drop = FALSE],
                    u[1L:(n - h), , drop = FALSE]) / n
    S  <- S + w * (Gh + t(Gh))
  }
  V_manual <- n * solve(crossprod(X)) %*% S %*% solve(crossprod(X))
  expect_lt(max(abs(V_nw - V_manual)), 1e-12)
})

test_that("nw_vcov rejects pre-whitening and non-lm input", {
  set.seed(4)
  fit <- stats::lm(rnorm(20) ~ seq_len(20))
  expect_error(nw_vcov(fit, lag = 3L, prewhite = TRUE), "prewhite")
  expect_error(nw_vcov(list(), lag = 1L),               "lm object")
  expect_error(nw_vcov(fit, lag = 1.5),                 "non-negative integer")
})
