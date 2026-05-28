test_that("convert_nowcast_chain_volume applies growth-rate pass-through", {
  # Synthetic DISR history: iron_ore + coal sub-commodities
  disr_hist <- tibble::tibble(
    quarter_end = rep(as.Date(c("2024-06-30", "2025-06-30")), 3),
    commodity   = rep(c("iron_ore", "coal_met", "coal_thermal"), each = 2),
    tonnes_Mt   = c(200, 220,    # iron_ore: Q-4 = 200, current = 220
                    80,  88,     # coal_met
                    120, 132)    # coal_thermal  -> total coal: 200, 220
  )

  # ABS chain-volume: year-ago quarter values
  abs_cv <- tibble::tibble(
    quarter_end  = as.Date(c("2024-06-30", "2024-06-30")),
    commodity    = c("iron_ore", "coal_total"),
    chain_vol_Am = c(50000, 10000),  # A$m
    series_id    = c("A3535047K", "A3535048L"),
    ingested_at  = Sys.time()
  )

  # Nowcast output for 2025-Q2 (horizon 0)
  nowcast <- tibble::tibble(
    commodity         = c("iron_ore", "coal_met", "coal_thermal"),
    quarter_end       = as.Date("2025-06-30"),
    point_estimate_Mt = c(220, 88, 132),
    lower_80          = c(210, 84, 126),
    upper_80          = c(230, 92, 138),
    lower_95          = c(200, 80, 120),
    upper_95          = c(240, 96, 144),
    share_observed    = 0.5,
    run_timestamp     = Sys.time(),
    horizon           = 0L
  )

  result <- convert_nowcast_chain_volume(nowcast, abs_cv, disr_hist)

  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 2)
  expect_true(all(c("iron_ore", "coal_total") %in% result$commodity))

  # Iron ore: growth = 220/200 = 1.1, so chain_vol = 50000 * 1.1 = 55000

  iron <- result[result$commodity == "iron_ore", ]
  expect_equal(iron$point_estimate_Am, 50000 * (220 / 200))
  expect_equal(iron$growth_factor, 1.1)
  expect_equal(iron$abs_lag4_Am, 50000)
  expect_equal(iron$disr_lag4_Mt, 200)

  # Coal total: DISR lag4 = 80+120 = 200, nowcast = 88+132 = 220
  # growth = 220/200 = 1.1, chain_vol = 10000 * 1.1 = 11000
  coal <- result[result$commodity == "coal_total", ]
  expect_equal(coal$point_estimate_Am, 10000 * 1.1)
  expect_equal(coal$growth_factor, 1.1)

  # Bands incorporate chain-volume bridge uncertainty on top of tonnage
  # uncertainty, so they are wider than a simple linear pass-through
  # and strictly bracket the point estimate.
  expect_lt(iron$lower_80_Am, iron$point_estimate_Am)
  expect_gt(iron$upper_80_Am, iron$point_estimate_Am)
  expect_lt(iron$lower_95_Am, iron$lower_80_Am)
  expect_gt(iron$upper_95_Am, iron$upper_80_Am)

  expect_lt(coal$lower_80_Am, coal$point_estimate_Am)
  expect_gt(coal$upper_80_Am, coal$point_estimate_Am)
})

test_that("convert_nowcast_chain_volume returns empty on missing inputs", {
  expect_equal(nrow(convert_nowcast_chain_volume(NULL, NULL, NULL)), 0)

  empty_nc <- tibble::tibble(
    commodity = character(), quarter_end = as.Date(character()),
    point_estimate_Mt = double(), lower_80 = double(),
    upper_80 = double(), lower_95 = double(), upper_95 = double(),
    share_observed = double(), run_timestamp = as.POSIXct(character()),
    horizon = integer()
  )
  expect_equal(
    nrow(convert_nowcast_chain_volume(empty_nc, empty_abs_chain_vol(),
                                      tibble::tibble())),
    0
  )
})

test_that("find_gap_quarters identifies missing quarters correctly", {
  # One gap quarter
  gaps <- find_gap_quarters(as.Date("2025-12-31"), as.Date("2026-06-30"))
  expect_equal(gaps, as.Date("2026-03-31"))

  # No gap
  gaps <- find_gap_quarters(as.Date("2026-03-31"), as.Date("2026-06-30"))
  expect_length(gaps, 0)

  # Two gap quarters
  gaps <- find_gap_quarters(as.Date("2025-09-30"), as.Date("2026-06-30"))
  expect_equal(gaps, as.Date(c("2025-12-31", "2026-03-31")))

  # Latest ABS IS the first nowcast quarter
  gaps <- find_gap_quarters(as.Date("2026-06-30"), as.Date("2026-06-30"))
  expect_length(gaps, 0)
})

test_that("convert_nowcast_chain_volume handles multiple horizons", {
  disr_hist <- tibble::tibble(
    quarter_end = rep(as.Date(c("2024-06-30", "2024-09-30")), each = 1),
    commodity   = "iron_ore",
    tonnes_Mt   = c(200, 210)
  )

  abs_cv <- tibble::tibble(
    quarter_end  = as.Date(c("2024-06-30", "2024-09-30")),
    commodity    = "iron_ore",
    chain_vol_Am = c(50000, 52000),
    series_id    = "A3535047K",
    ingested_at  = Sys.time()
  )

  nowcast <- tibble::tibble(
    commodity         = c("iron_ore", "iron_ore"),
    quarter_end       = as.Date(c("2025-06-30", "2025-09-30")),
    point_estimate_Mt = c(220, 230),
    lower_80          = c(210, 220),
    upper_80          = c(230, 240),
    lower_95          = c(200, 210),
    upper_95          = c(240, 250),
    share_observed    = c(0.5, 0),
    run_timestamp     = Sys.time(),
    horizon           = c(0L, 1L)
  )

  result <- convert_nowcast_chain_volume(nowcast, abs_cv, disr_hist)
  expect_equal(nrow(result), 2)
  expect_equal(result$horizon, c(0L, 1L))

  # h=0: growth 220/200 = 1.1, cv = 50000*1.1 = 55000
  expect_equal(result$point_estimate_Am[1], 55000)
  # h=1: growth 230/210 ≈ 1.095, cv = 52000 * 230/210
  expect_equal(result$point_estimate_Am[2], 52000 * (230 / 210))
})
