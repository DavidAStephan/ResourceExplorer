test_that("parse_abs_5368 keeps only configured SITC codes", {
  cfg <- list(abs = list(commodity_sitc = list(
    iron_ore = "281", coal = c("321", "322"), lng = "343"
  )))

  raw <- tibble::tibble(
    date      = as.Date(c("2024-01-01", "2024-02-01", "2024-01-01",
                          "2024-01-01", "2024-01-01")),
    series    = c("Iron ore and concentrates (SITC 281)",
                  "Iron ore and concentrates (SITC 281)",
                  "Coal, coke and briquettes (SITC 321)",
                  "Natural gas (SITC 343)",
                  "Gold (SITC 971)"),
    series_id = c("A_IRON", "A_IRON", "A_COAL", "A_LNG", "A_GOLD"),
    value     = c(12000, 13000, 9000, 7000, 5000)
  )

  out <- parse_abs_5368(raw, cfg)
  expect_equal(nrow(out), 4)
  expect_false("A_GOLD" %in% out$series_id)
  expect_setequal(out$sitc, c("281", "321", "343"))
  expect_true(all(lubridate::day(out$month_end) %in% c(28L, 29L, 30L, 31L)))
})

test_that("parse_abs_5302 separates current-price and chain-volume", {
  raw <- tibble::tibble(
    date = as.Date(c("2024-03-31", "2024-03-31")),
    series = c(
      "Goods credits, Current prices",
      "Goods credits, Chain volume measures"
    ),
    series_id = c("A_CUR", "A_CV"),
    value = c(180000, 150000)
  )

  out <- parse_abs_5302(raw)
  cur <- dplyr::filter(out, series_id == "A_CUR")
  cv  <- dplyr::filter(out, series_id == "A_CV")

  expect_equal(cur$value_current_aud_m, 180000)
  expect_true(is.na(cur$value_chainvol_aud_m))
  expect_equal(cv$value_chainvol_aud_m, 150000)
  expect_true(is.na(cv$value_current_aud_m))
})

test_that("parse_abs_5368 handles zero matches without error", {
  cfg <- list(abs = list(commodity_sitc = list(iron_ore = "281")))
  raw <- tibble::tibble(
    date = as.Date("2024-01-01"),
    series = "Unrelated series",
    series_id = "X",
    value = 1
  )
  out <- parse_abs_5368(raw, cfg)
  expect_equal(nrow(out), 0)
})
