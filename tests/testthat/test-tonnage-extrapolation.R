fixture_portwatch <- function() {
  # Two AUS ports, 2 commodities, 3 years of daily data with known seasonal
  # pattern so we can reason about the outputs.
  set.seed(42)
  dates <- seq(as.Date("2020-01-01"), as.Date("2023-12-31"), by = "day")
  ports <- tibble::tibble(
    port_id   = c("P1", "P2"),
    commodity = c("iron_ore", "iron_ore")
  )
  purrr::map_dfr(seq_len(nrow(ports)), function(i) {
    tibble::tibble(
      obs_date     = dates,
      port_id      = ports$port_id[i],
      commodity    = ports$commodity[i],
      tonnage      = 1000 + 200 * sin(2 * pi * lubridate::yday(dates) / 365) +
                       stats::rnorm(length(dates), 0, 50),
      vessel_count = 1L,
      ingested_at  = Sys.time()
    )
  })
}

fixture_ports <- function() {
  tibble::tibble(
    port_id         = c("P1", "P2"),
    port_name       = c("P1", "P2"),
    iso3            = "AUS",
    lat = 0, lon = 0,
    commodity_class = c("iron_ore", "iron_ore"),
    sitc_map        = "281"
  )
}

test_that("extrapolate_quarter_tonnage flags observed/partial/estimated", {
  pw <- fixture_portwatch()
  pm <- fixture_ports()
  cfg <- list(commodities = "iron_ore",
              sample = list(train_end = "2023-12-31"))

  # Mid-quarter: month 1 observed, month 2 partial, month 3 estimated.
  out <- extrapolate_quarter_tonnage(pw, pm, cfg, as_of = as.Date("2023-05-10"))

  expect_equal(nrow(out), 3)
  expect_setequal(out$status, c("observed", "partial", "estimated"))
  expect_true(all(out$tonnage_est > 0))
})

test_that("partial-month scale-up exceeds observed-to-date tonnage", {
  pw <- fixture_portwatch()
  pm <- fixture_ports()
  cfg <- list(commodities = "iron_ore",
              sample = list(train_end = "2023-12-31"))

  out <- extrapolate_quarter_tonnage(pw, pm, cfg, as_of = as.Date("2023-05-10"))
  partial <- dplyr::filter(out, status == "partial")

  observed_partial <- pw |>
    dplyr::filter(obs_date >= as.Date("2023-05-01"),
                  obs_date <= as.Date("2023-05-10")) |>
    dplyr::summarise(t = sum(tonnage)) |> dplyr::pull(t)

  expect_gt(partial$tonnage_est, observed_partial)
  expect_lt(partial$share_observed, 1)
})

test_that("empty portwatch produces NA tonnage with status=estimated", {
  empty <- tibble::tibble(
    obs_date = as.Date(character()), port_id = character(),
    commodity = character(), tonnage = double(),
    vessel_count = integer(),
    ingested_at = as.POSIXct(character(), tz = "UTC")
  )
  out <- extrapolate_quarter_tonnage(empty, fixture_ports(),
                                     list(commodities = "iron_ore"),
                                     as_of = as.Date("2023-05-10"))
  expect_true(all(is.na(out$tonnage_est)))
})
