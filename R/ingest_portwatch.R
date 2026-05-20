#' Fetch PortWatch daily tonnage from the IMF ArcGIS FeatureServer
#'
#' Queries the IMF PortWatch `Daily_Ports_Data` FeatureServer layer for
#' AUS-flagged (or configured `countries`) rows from
#' `cfg$sample$train_start` through `Sys.Date()`. The real layer delivers
#' one row per (port, day) with export tonnage split across vessel-type
#' columns (`export_dry_bulk`, `export_tanker`, `export_container`,
#' `export_general_cargo`, `export_roro`) and port-call counts.
#'
#' This function:
#'
#' 1. Paginates via `resultOffset`, parsing each page with
#'    [parse_portwatch_features()] into a wide tibble.
#' 2. Joins to the port metadata (`inst/extdata/ports_metadata.csv`) on
#'    `portname` to attach our commodity class.
#' 3. Derives commodity rows via [derive_portwatch_commodity_rows()] --
#'    one row per (obs_date, port, commodity) with summed tonnage.
#' 4. Writes the long tibble to the rds warehouse and appends a row to
#'    `mart_ingest_runs`.
#' 5. Falls back to the most recent RDS cache on any error so the
#'    pipeline runs offline.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle (unused; kept for signature parity).
#' @return Tibble: `obs_date`, `port_id`, `commodity`, `tonnage`,
#'   `vessel_count`, `ingested_at`.
#' @export
fetch_portwatch_tonnage <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"
  ports_metadata <- tryCatch(
    readr::read_csv(cfg$paths$ports_metadata, show_col_types = FALSE),
    error = function(e) tibble::tibble(port_name = character(),
                                        commodity_class = character())
  )

  result <- tryCatch({
    wide <- with_cache(cfg, "portwatch", "daily_ports_data", function() {
      out <- pull_portwatch_pages(cfg)
      # An empty response is almost always a rate-limit / transient
      # server issue, not a real "no data" state. Treat it as a fetch
      # failure so `with_cache` falls back to the previous good cache
      # rather than poisoning it with a zero-row tibble.
      if (nrow(out) == 0L) {
        stop("pull_portwatch_pages returned 0 rows (likely rate-limited)",
             call. = FALSE)
      }
      out
    })
    if (identical(attr(wide, "cache_status"), "stale")) status <- "cached"
    derive_portwatch_commodity_rows(wide, ports_metadata)
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "portwatch", started, 0L, "error",
                   conditionMessage(e))
    stop(e)
  })

  wh_write("raw_portwatch_tonnage_daily", result, cfg)

  log_ingest_run(cfg, "portwatch", started, nrow(result), status)
  log_info("fetch_portwatch_tonnage -- %d rows (%s)", nrow(result), status)
  result
}

#' Page through the FeatureServer and return the union as a wide tibble
#'
#' Returned columns mirror the ArcGIS schema: `obs_date`, `portid`,
#' `portname`, `export_dry_bulk`, `export_tanker`, `export_container`,
#' `export_general_cargo`, `export_roro`, `portcalls`. A final
#' `ingested_at` column tracks fetch timestamp.
#'
#' **Why per-port**: The IMF ArcGIS server silently stops returning rows
#' when `resultOffset` exceeds ~5000 even though the layer claims
#' `supportsPagination = TRUE` and `maxRecordCount = 1000`. Querying the
#' full country panel in one cursor caps us at 5000/151449 rows
#' (observed 2026-04-21). We work around by listing every port once,
#' then querying each port independently (~2657 daily rows per port ==
#' 3 pages of 1000). Each port's pagination stays well below the server's
#' offset ceiling.
#'
#' @keywords internal
pull_portwatch_pages <- function(cfg) {
  base <- Sys.getenv("PORTWATCH_BASE_URL", unset = cfg$portwatch$base_url)
  start_date <- format(as.Date(cfg$sample$train_start), "%Y-%m-%d")

  portids <- portwatch_list_portids(base, cfg$portwatch$countries, cfg)
  log_info("portwatch: discovered %d ports in scope", length(portids))

  out_fields <- paste(
    "date,portid,portname,ISO3",
    "export_dry_bulk,export_tanker,export_container",
    "export_general_cargo,export_roro,portcalls",
    sep = ","
  )
  page_size <- cfg$portwatch$page_size %||% 1000
  acc <- list()

  for (i in seq_along(portids)) {
    pid <- portids[[i]]
    offset <- 0L
    total_port_rows <- 0L
    repeat {
      where <- sprintf("portid = '%s' AND date >= DATE '%s'", pid, start_date)
      req <- make_request(
        file.path(base, "query"),
        max_attempts    = cfg$portwatch$retry$max_attempts %||% 3,
        backoff_seconds = cfg$portwatch$retry$backoff_seconds %||% 5
      ) |>
        httr2::req_url_query(
          where             = where,
          outFields         = out_fields,
          f                 = "json",
          resultOffset      = offset,
          resultRecordCount = page_size,
          returnGeometry    = "false",
          orderByFields     = "date"
        )

      resp   <- httr2::req_perform(req)
      body   <- httr2::resp_body_string(resp)
      parsed <- jsonlite::fromJSON(body, simplifyVector = TRUE)
      page   <- parse_portwatch_features(body)
      acc[[length(acc) + 1L]] <- page
      total_port_rows <- total_port_rows + nrow(page)

      more <- isTRUE(parsed$exceededTransferLimit) ||
              (is.null(parsed$exceededTransferLimit) && nrow(page) >= page_size)
      if (!more) break
      offset <- offset + page_size
    }
    log_info("portwatch [%3d/%3d] %-10s rows=%d",
             i, length(portids), pid, total_port_rows)
    # Gentle rate-limit buffer; the ArcGIS service starts returning
    # empty responses after bursts of >~100 requests without pauses.
    Sys.sleep(0.2)
  }

  dplyr::bind_rows(acc)
}

#' List unique portids in scope via a distinct-values query.
#'
#' @keywords internal
portwatch_list_portids <- function(base, countries, cfg) {
  country_list <- paste(sprintf("'%s'", countries), collapse = ",")
  where <- sprintf("ISO3 IN (%s)", country_list)

  req <- make_request(
    file.path(base, "query"),
    max_attempts    = cfg$portwatch$retry$max_attempts %||% 3,
    backoff_seconds = cfg$portwatch$retry$backoff_seconds %||% 5
  ) |>
    httr2::req_url_query(
      where                = where,
      outFields            = "portid",
      returnDistinctValues = "true",
      returnGeometry       = "false",
      f                    = "json",
      resultRecordCount    = 2000
    )

  body   <- httr2::resp_body_string(httr2::req_perform(req))
  parsed <- jsonlite::fromJSON(body, simplifyVector = TRUE)
  if (is.null(parsed$features) || length(parsed$features) == 0) {
    return(character(0))
  }
  attrs <- if (is.data.frame(parsed$features$attributes)) {
    parsed$features$attributes
  } else {
    parsed$features
  }
  sort(unique(as.character(attrs$portid)))
}

#' Parse an ArcGIS FeatureServer JSON body into a wide per-port-day tibble.
#'
#' Returns the minimum set of columns we use downstream; unused IMF
#' columns (country, year, import_*) are dropped on ingestion to keep
#' the warehouse tight.
#'
#' @param json_body Raw JSON string from the FeatureServer `query` endpoint.
#' @return Wide tibble: `obs_date`, `portid`, `portname`,
#'   `export_dry_bulk`, `export_tanker`, `export_container`,
#'   `export_general_cargo`, `export_roro`, `portcalls`, `ingested_at`.
#' @keywords internal
parse_portwatch_features <- function(json_body) {
  parsed <- jsonlite::fromJSON(json_body, simplifyVector = TRUE)
  feats <- parsed$features

  empty <- tibble::tibble(
    obs_date             = as.Date(character()),
    portid               = character(),
    portname             = character(),
    export_dry_bulk      = integer(),
    export_tanker        = integer(),
    export_container     = integer(),
    export_general_cargo = integer(),
    export_roro          = integer(),
    portcalls            = integer(),
    ingested_at          = as.POSIXct(character(), tz = "UTC")
  )
  if (is.null(feats) || length(feats) == 0) return(empty)

  attrs <- if (is.data.frame(feats$attributes)) feats$attributes else feats

  pick <- function(..., default = NA) {
    for (nm in c(...)) if (nm %in% names(attrs)) return(attrs[[nm]])
    rep(default, nrow(attrs))
  }

  # ArcGIS returns `date` as ISO "YYYY-MM-DD" for `esriFieldTypeDateOnly`
  # and as epoch-ms numeric for `esriFieldTypeDate`. Handle both.
  date_raw <- pick("date", "ObsDate", "obs_date", default = NA_character_)
  obs_date <- if (is.numeric(date_raw)) {
    as.Date(as.POSIXct(date_raw / 1000, origin = "1970-01-01", tz = "UTC"))
  } else {
    as.Date(date_raw)
  }

  out <- tibble::tibble(
    obs_date             = obs_date,
    portid               = as.character(pick("portid", "PortID", default = NA_character_)),
    portname             = as.character(pick("portname", "PortName", default = NA_character_)),
    export_dry_bulk      = as.integer(pick("export_dry_bulk", default = 0L)),
    export_tanker        = as.integer(pick("export_tanker", default = 0L)),
    export_container     = as.integer(pick("export_container", default = 0L)),
    export_general_cargo = as.integer(pick("export_general_cargo", default = 0L)),
    export_roro          = as.integer(pick("export_roro", default = 0L)),
    portcalls            = as.integer(pick("portcalls", default = 0L)),
    ingested_at          = Sys.time()
  )
  out[!is.na(out$obs_date) & !is.na(out$portid), ]
}

#' Derive one row per (obs_date, port, commodity) from the wide schema.
#'
#' **Commodity rules.**
#'
#' - `export_dry_bulk` at an iron-ore-class port -> `iron_ore`.
#' - `export_dry_bulk` at a coal-class port -> `coal`.
#' - Tanker tonnage and all other vessel types -> dropped. LNG was
#'   scoped out 2026-04-21 (PortWatch tanker tonnage has near-zero
#'   correlation with ABS LNG volumes — Australian LNG is contract-
#'   dominated, not vessel-call-dominated). Iron-ore + coal are the
#'   only commodities the bridge consumes.
#'
#' Port commodity classes come from `inst/extdata/ports_metadata.csv`
#' via a join on `portname`.
#'
#' Zero-tonnage rows are dropped.
#'
#' @param wide Tibble from [parse_portwatch_features()] (one row per
#'   port-day, wide on vessel-type columns).
#' @param ports_metadata Tibble with `port_name` and `commodity_class`
#'   columns. Other columns are ignored.
#' @param ... Swallows legacy positional / named arguments (e.g.
#'   `lng_ports` from before the 2026-05-20 LNG removal) so external
#'   callers don't break across the signature change.
#' @return Long tibble: `obs_date`, `port_id`, `commodity`, `tonnage`,
#'   `vessel_count`, `ingested_at`.
#' @export
derive_portwatch_commodity_rows <- function(wide, ports_metadata, ...) {
  # Variadic `...` swallows the legacy `lng_ports = ...` argument so any
  # external caller from before the 2026-05-20 LNG removal still works.
  empty <- tibble::tibble(
    obs_date     = as.Date(character()),
    port_id      = character(),
    commodity    = character(),
    tonnage      = double(),
    vessel_count = integer(),
    ingested_at  = as.POSIXct(character(), tz = "UTC")
  )
  if (nrow(wide) == 0) return(empty)

  ports_min <- ports_metadata |>
    dplyr::transmute(
      portname        = .data$port_name,
      commodity_class = .data$commodity_class
    )

  long <- wide |>
    dplyr::left_join(ports_min, by = "portname") |>
    dplyr::mutate(
      commodity_class = dplyr::coalesce(.data$commodity_class, "other")
    ) |>
    tidyr::pivot_longer(
      cols      = dplyr::starts_with("export_"),
      names_to  = "vessel_type",
      values_to = "tonnage",
      names_prefix = "export_"
    ) |>
    dplyr::mutate(
      tonnage = as.double(.data$tonnage),
      commodity = dplyr::case_when(
        .data$vessel_type == "dry_bulk" & .data$commodity_class == "iron_ore" ~ "iron_ore",
        .data$vessel_type == "dry_bulk" & .data$commodity_class == "coal"     ~ "coal",
        TRUE                                                                   ~ NA_character_
      )
    ) |>
    dplyr::filter(!is.na(.data$tonnage), .data$tonnage > 0,
                  !is.na(.data$commodity)) |>
    dplyr::group_by(.data$obs_date, .data$portid, .data$commodity) |>
    dplyr::summarise(
      tonnage      = sum(.data$tonnage, na.rm = TRUE),
      # portcalls is per port-day (not per vessel type), so divide by 5
      # vessel-type rows to avoid double-counting on the collapse. Rounded
      # down and floored at the original count for the dominant vessel
      # type on a given day.
      vessel_count = as.integer(ceiling(sum(.data$portcalls, na.rm = TRUE) / 5L)),
      .groups      = "drop"
    ) |>
    dplyr::transmute(
      obs_date     = .data$obs_date,
      port_id      = .data$portid,
      commodity    = .data$commodity,
      tonnage      = .data$tonnage,
      vessel_count = .data$vessel_count,
      ingested_at  = Sys.time()
    )

  long
}
