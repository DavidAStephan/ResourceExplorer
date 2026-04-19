#' Load the commodity -> SITC crosswalk and upsert into `mart.crosswalk_sitc`
#'
#' @param cfg Config list.
#' @return The crosswalk tibble.
#' @export
load_sitc_crosswalk <- function(cfg) {
  path <- cfg$paths$sitc_crosswalk
  if (!fs::file_exists(path)) {
    stop("sitc_crosswalk.csv not found at ", path, call. = FALSE)
  }

  xw <- readr::read_csv(
    path,
    col_types = readr::cols(
      commodity  = readr::col_character(),
      sitc       = readr::col_character(),
      is_primary = readr::col_logical(),
      notes      = readr::col_character()
    )
  )

  config_commodities <- setdiff(cfg$commodities, "other")
  missing_commodities <- setdiff(config_commodities, unique(xw$commodity))
  if (length(missing_commodities)) {
    stop("sitc_crosswalk.csv is missing rows for commodities: ",
         paste(missing_commodities, collapse = ", "), call. = FALSE)
  }

  con <- warehouse_connect(cfg)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DELETE FROM mart.crosswalk_sitc")
  DBI::dbWriteTable(con,
                    DBI::Id(schema = "mart", table = "crosswalk_sitc"),
                    xw, append = TRUE)

  logger::log_info("load_sitc_crosswalk -- {nrow(xw)} rows",
                   namespace = "resourcetracker")
  xw
}

#' Reverse lookup: which of our commodities does an SITC code belong to?
#'
#' @param sitc_codes Character vector of 3-digit SITC codes.
#' @param crosswalk The tibble returned by [load_sitc_crosswalk()].
#' @return Character vector of commodity labels, `NA` for unmapped codes.
#' @keywords internal
sitc_to_commodity <- function(sitc_codes, crosswalk) {
  idx <- match(sitc_codes, crosswalk$sitc)
  crosswalk$commodity[idx]
}
