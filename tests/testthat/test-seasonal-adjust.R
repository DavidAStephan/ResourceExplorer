test_that("x13_adjust returns value_sa for a 5-year monthly series", {
  skip_if_not_installed("seasonal")
  skip_on_cran()

  n <- 60
  month_end <- seq(as.Date("2018-01-01"), by = "month", length.out = n)
  month_end <- lubridate::ceiling_date(month_end, "month") - 1
  t <- seq_len(n)
  seasonal_pattern <- 0.15 * sin(2 * pi * t / 12)
  trend <- 0.01 * t
  value <- exp(4 + trend + seasonal_pattern + stats::rnorm(n, 0, 0.05))

  df <- tibble::tibble(month_end = month_end, value = value)
  out <- x13_adjust(df)

  expect_true("value_sa" %in% names(out))
  expect_equal(nrow(out), n)
  # SA series should have smaller seasonal variance than raw
  raw_var <- stats::var(diff(out$value, lag = 12))
  sa_var  <- stats::var(diff(out$value_sa, lag = 12))
  expect_lt(sa_var, raw_var)
})

test_that("x13_adjust returns original series when n < 36", {
  df <- tibble::tibble(
    month_end = seq(as.Date("2022-01-01"), by = "month", length.out = 24) |>
      (\(d) lubridate::ceiling_date(d, "month") - 1)(),
    value     = stats::rnorm(24, 100, 10)
  )
  out <- x13_adjust(df)
  expect_equal(out$value_sa, out$value)
})

test_that("x13_adjust handles empty input", {
  out <- x13_adjust(tibble::tibble(
    month_end = as.Date(character()),
    value = double()
  ))
  expect_equal(nrow(out), 0)
  expect_true("value_sa" %in% names(out))
})
