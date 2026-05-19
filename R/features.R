#' Build the MIDAS-style quarterly feature panel
#'
#' One row per (`commodity`, `quarter_end`). The "MIDAS" (mixed-data
#' sampling) part: each quarter is broken into three monthly positions
#' (`m1`, `m2`, `m3`) so the bridge can weight within-quarter timing
#' differently for each — useful because PortWatch tonnage for, say,
#' the first month of a quarter is mechanically a better indicator of
#' that quarter's exports than the third (which is still being filled
#' in at nowcast time).
#'
#' Columns:
#'
#' | column                   | meaning                                      |
#' |--------------------------|----------------------------------------------|
#' | `commodity`              | one of `iron_ore`, `coal`                    |
#' | `quarter_end`            | last day of the quarter                      |
#' | `volume_Mt`              | LHS target: DISR REQ T16 physical Mt         |
#' | `tonnage`                | total quarterly PortWatch tonnage (sum m1+m2+m3) |
#' | `tonnage_m1` .. `_m3`    | PortWatch tonnage in each month of the quarter |
#' | `log_volume`             | log of LHS                                   |
#' | `log_tonnage_m1` .. `_m3`| logs of monthly positions                    |
#' | `log_volume_lag4`        | year-ago LHS (seasonal anchor)               |
#' | `yoy_log_volume`         | YoY Δ of LHS (used by the `bojo` spec)       |
#' | `yoy_log_tonnage_m1` .. `_m3` | YoY Δ of each monthly position (RHS in bridge) |
#'
#' YoY differencing on each monthly position strips out seasonality
#' mechanically, so no STL / X-13 is applied here.
#'
#' @param portwatch Daily tonnage tibble from [fetch_portwatch_tonnage()].
#' @param disr_req Quarterly physical-volume tibble from
#'   [fetch_disr_req()] with columns `quarter_end`, `commodity`,
#'   `tonnes_Mt`.
#' @param cfg Config list.
#' @return Tibble keyed by `(commodity, quarter_end)`.
#' @export
build_features <- function(portwatch, disr_req, cfg) {
  commodities <- cfg$commodities

  tonnage_m <- aggregate_monthly_tonnage_mwq(portwatch, commodities)

  # LHS: physical tonnage (Mt) by commodity, quarterly.
  lhs <- disr_req |>
    dplyr::filter(.data$commodity %in% commodities) |>
    dplyr::transmute(.data$commodity, .data$quarter_end,
                     volume_Mt = .data$tonnes_Mt)

  wide <- tonnage_m |>
    dplyr::select(.data$commodity, .data$quarter_end, .data$mwq,
                  .data$tonnage) |>
    tidyr::pivot_wider(names_from  = "mwq",
                       values_from = "tonnage",
                       names_prefix = "tonnage_m",
                       values_fill  = 0)

  # Some quarters might miss a monthly column if PortWatch has no rows
  # for that month. Guarantee all three exist.
  for (k in 1:3) {
    col <- paste0("tonnage_m", k)
    if (!col %in% names(wide)) wide[[col]] <- 0
  }

  feats <- dplyr::inner_join(lhs, wide, by = c("commodity", "quarter_end"))

  feats |>
    dplyr::group_by(.data$commodity) |>
    dplyr::arrange(.data$quarter_end, .by_group = TRUE) |>
    dplyr::mutate(
      tonnage             = .data$tonnage_m1 + .data$tonnage_m2 +
                            .data$tonnage_m3,
      log_volume          = log(pmax(.data$volume_Mt,   1e-6)),
      log_tonnage         = log(pmax(.data$tonnage,     1e-6)),
      log_tonnage_m1      = log(pmax(.data$tonnage_m1,  1e-6)),
      log_tonnage_m2      = log(pmax(.data$tonnage_m2,  1e-6)),
      log_tonnage_m3      = log(pmax(.data$tonnage_m3,  1e-6)),
      log_volume_lag4     = dplyr::lag(.data$log_volume, 4L),
      # YoY log-difference of the LHS -- the dependent variable when the
      # bridge is fit in pure differenced form (`bojo` spec, which
      # forces beta_lag4 = 1).
      yoy_log_volume      = .data$log_volume -
                             dplyr::lag(.data$log_volume, 4L),
      # Aggregate YoY: log ratio of quarterly tonnage totals; for the
      # `spec = "aggregate"` bridge variant.
      yoy_log_tonnage     = .data$log_tonnage -
                             dplyr::lag(.data$log_tonnage, 4L),
      # Per-month YoY: for the `spec = "midas"` bridge variant.
      yoy_log_tonnage_m1  = .data$log_tonnage_m1 -
                             dplyr::lag(.data$log_tonnage_m1, 4L),
      yoy_log_tonnage_m2  = .data$log_tonnage_m2 -
                             dplyr::lag(.data$log_tonnage_m2, 4L),
      yoy_log_tonnage_m3  = .data$log_tonnage_m3 -
                             dplyr::lag(.data$log_tonnage_m3, 4L)
    ) |>
    dplyr::ungroup() |>
    dplyr::filter(is.finite(.data$log_volume))
}

#' Aggregate daily PortWatch tonnage to (commodity × quarter × month-in-quarter)
#'
#' Returns one row per (commodity, quarter_end, mwq) where `mwq` is 1/2/3
#' for the first/second/third month of that quarter.
#' @keywords internal
aggregate_monthly_tonnage_mwq <- function(portwatch, commodities) {
  empty <- tibble::tibble(
    commodity   = character(),
    quarter_end = as.Date(character()),
    mwq         = integer(),
    tonnage     = double()
  )
  if (nrow(portwatch) == 0L) return(empty)

  portwatch |>
    dplyr::filter(.data$commodity %in% commodities) |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(.data$obs_date, "quarter") - 1,
      mwq         = ((lubridate::month(.data$obs_date) - 1L) %% 3L) + 1L
    ) |>
    dplyr::group_by(.data$commodity, .data$quarter_end, .data$mwq) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")
}
