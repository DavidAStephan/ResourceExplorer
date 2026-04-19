#' Fetch PortWatch daily tonnage from the IMF ArcGIS FeatureServer
#'
#' Queries the FeatureServer for AUS-flagged (or configured `countries`)
#' port trade rows from `cfg$sample$train_start` to `Sys.Date()`, paginates
#' via `resultOffset`, writes to `raw.portwatch_tonnage_daily`, and logs a
#' row to `mart.ingest_runs`. Falls back to the most recent RDS cache on
#' any error so the DAG can run offline.
#'
#' Field names on the FeatureServer are the IMF's -- we map to our schema:
#' `ObsDate` -> `obs_date`, `PortID` (or similar) -> `port_id`, etc. The
#' exact source field names are confirmed on first live run; the parser
#' [parse_portwatch_features()] isolates that concern for testability.
#'
#' @param cfg Config list.
#' @param db_ready Dependency handle from [warehouse_init_schema()].
#' @return Tibble matching `raw.portwatch_tonnage_daily`.
#' @export
fetch_portwatch_tonnage <- function(cfg, db_ready) {
  started <- Sys.time()
  status  <- "ok"
  result  <- tryCatch({
    df <- with_cache(cfg, "portwatch", "daily_trade_panel", function() {
      pull_portwatch_pages(cfg)
    })
    if (identical(attr(df, "cache_status"), "stale")) status <- "cached"
    df
  },
  error = function(e) {
    status <<- "error"
    log_ingest_run(cfg, "portwatch", started, 0L, "error",
                   conditionMessage(e))
    stop(e)
  })

  con <- warehouse_connect(cfg)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DELETE FROM raw.portwatch_tonnage_daily")
  if (nrow(result) > 0) {
    DBI::dbWriteTable(con,
                      DBI::Id(schema = "raw", table = "portwatch_tonnage_daily"),
                      result, append = TRUE)
  }

  log_ingest_run(cfg, "portwatch", started, nrow(result), status)
  logger::log_info("fetch_portwatch_tonnage -- {nrow(result)} rows ({status})",
                   namespace = "resourcetracker")
  result
}

#' Page through the FeatureServer and return the union as a tibble
#' @keywords internal
pull_portwatch_pages <- function(cfg) {
  base <- Sys.getenv("PORTWATCH_BASE_URL", unset = cfg$portwatch$base_url)
  countries <- paste(sprintf("'%s'", cfg$portwatch$countries), collapse = ",")
  where <- sprintf("iso3 IN (%s) AND ObsDate >= DATE '%s'",
                   countries, cfg$sample$train_start)

  page_size <- cfg$portwatch$page_size %||% 2000
  offset <- 0L
  acc <- list()

  repeat {
    req <- make_request(
      file.path(base, "query"),
      max_attempts    = cfg$portwatch$retry$max_attempts %||% 3,
      backoff_seconds = cfg$portwatch$retry$backoff_seconds %||% 5
    ) |>
      httr2::req_url_query(
        where               = where,
        outFields           = "*",
        f                   = "json",
        resultOffset        = offset,
        resultRecordCount   = page_size,
        returnGeometry      = "false"
      )

    resp <- httr2::req_perform(req)
    body <- httr2::resp_body_string(resp)
    page <- parse_portwatch_features(body)
    acc[[length(acc) + 1L]] <- page
    logger::log_debug("portwatch page offset={offset} rows={nrow(page)}",
                      namespace = "resourcetracker")

    if (nrow(page) < page_size) break
    offset <- offset + page_size
  }

  dplyr::bind_rows(acc)
}

#' Parse an ArcGIS FeatureServer JSON body into our canonical schema.
#'
#' Isolated from [pull_portwatch_pages()] so tests can hit it with a
#' fixture string. Handles the IMF field-name variation by best-effort
#' matching on common spellings.
#'
#' @param json_body Raw JSON string from the FeatureServer `query` endpoint.
#' @return Tibble matching `raw.portwatch_tonnage_daily`.
#' @keywords internal
parse_portwatch_features <- function(json_body) {
  parsed <- jsonlite::fromJSON(json_body, simplifyVector = TRUE)
  feats <- parsed$features

  empty <- tibble::tibble(
    obs_date     = as.Date(character()),
    port_id      = character(),
    commodity    = character(),
    tonnage      = double(),
    vessel_count = integer(),
    ingested_at  = as.POSIXct(character(), tz = "UTC")
  )
  if (is.null(feats) || length(feats) == 0) return(empty)

  attrs <- if (is.data.frame(feats$attributes)) feats$attributes else feats
  # Best-effort canonicalisation of IMF's field names.
  pick <- function(...) {
    for (nm in c(...)) if (nm %in% names(attrs)) return(attrs[[nm]])
    NULL
  }

  obs_raw <- pick("ObsDate", "obs_date", "date")
  obs_date <- if (is.numeric(obs_raw)) {
    as.Date(as.POSIXct(obs_raw / 1000, origin = "1970-01-01", tz = "UTC"))
  } else as.Date(obs_raw)

  out <- tibble::tibble(
    obs_date     = obs_date,
    port_id      = as.character(pick("PortID", "port_id", "portid", "id") %||% NA_character_),
    commodity    = as.character(pick("CommodityGroup", "commodity", "Commodity") %||% NA_character_),
    tonnage      = as.numeric(pick("Tonnage", "tonnage", "volume_tons") %||% NA_real_),
    vessel_count = as.integer(pick("VesselCount", "vessel_count", "vessels") %||% NA_integer_),
    ingested_at  = Sys.time()
  )
  out[!is.na(out$obs_date) & !is.na(out$port_id), ]
}
