test_that("stl_quarterly_adjust deseasonalises a 32-quarter series", {
  n <- 32
  q_floor <- seq(as.Date("2019-01-01"), by = "3 months", length.out = n)
  q_end <- lubridate::ceiling_date(q_floor, "quarter") - 1
  t <- seq_len(n)
  seasonal <- 0.20 * sin(2 * pi * t / 4)
  trend    <- 0.01 * t
  set.seed(7)
  value    <- exp(4 + trend + seasonal + stats::rnorm(n, 0, 0.03))
  df <- tibble::tibble(quarter_end = q_end, value = value)

  out <- stl_quarterly_adjust(df)
  expect_true("value_sa" %in% names(out))
  expect_equal(nrow(out), n)

  # Seasonal pattern strength: variance of the mean BY quarter-of-year.
  # A well-adjusted series should have near-constant per-quarter means.
  raw_by_q <- tapply(out$value,    lubridate::quarter(out$quarter_end), mean)
  sa_by_q  <- tapply(out$value_sa, lubridate::quarter(out$quarter_end), mean)
  expect_lt(stats::var(sa_by_q), stats::var(raw_by_q))
})

test_that("stl_quarterly_adjust returns original when n < 8", {
  df <- tibble::tibble(
    quarter_end = seq(as.Date("2024-03-31"), by = "3 months", length.out = 6) |>
      (\(d) lubridate::ceiling_date(d, "quarter") - 1)(),
    value = stats::rnorm(6, 100, 10)
  )
  out <- stl_quarterly_adjust(df)
  expect_equal(out$value_sa, out$value)
})

test_that("stl_quarterly_adjust handles empty input", {
  out <- stl_quarterly_adjust(tibble::tibble(
    quarter_end = as.Date(character()),
    value       = double()
  ))
  expect_equal(nrow(out), 0)
  expect_true("value_sa" %in% names(out))
})
