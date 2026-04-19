test_that("implicit_deflator divides current by chainvol", {
  raw <- tibble::tibble(
    quarter_end           = as.Date(c("2023-12-31", "2024-03-31")),
    series_id             = "GOODS",
    value_current_aud_m   = c(200, 220),
    value_chainvol_aud_m  = c(160, 170),
    ingested_at           = Sys.time()
  )
  d <- implicit_deflator(raw)
  expect_equal(nrow(d), 2)
  expect_equal(d$deflator, c(200/160, 220/170))
})

test_that("apply_chain_volume uses trailing-mean deflator forecast", {
  deflators <- tibble::tibble(
    quarter_end = as.Date(c("2023-03-31", "2023-06-30",
                            "2023-09-30", "2023-12-31")),
    deflator    = c(1.10, 1.15, 1.20, 1.25)
  )
  preds <- tibble::tibble(
    quarter_end         = as.Date("2024-03-31"),
    value_current_aud_m = 240
  )
  out <- apply_chain_volume(preds, deflators, lookback = 4L)
  expected_d <- mean(c(1.10, 1.15, 1.20, 1.25))
  expect_equal(out$deflator_forecast, expected_d)
  expect_equal(out$value_chainvol_aud_m, 240 / expected_d)
})

test_that("apply_chain_volume gives NA deflator when no history exists", {
  deflators <- tibble::tibble(
    quarter_end = as.Date(character()),
    deflator = double()
  )
  preds <- tibble::tibble(
    quarter_end = as.Date("2024-03-31"),
    value_current_aud_m = 240
  )
  out <- apply_chain_volume(preds, deflators)
  expect_true(is.na(out$deflator_forecast))
  expect_true(is.na(out$value_chainvol_aud_m))
})
