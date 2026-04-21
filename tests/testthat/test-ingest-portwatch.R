test_that("parse_portwatch_features handles empty feature list", {
  body <- '{"features": []}'
  out <- parse_portwatch_features(body)
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 0)
  expect_named(out, c("obs_date", "portid", "portname",
                      "export_dry_bulk", "export_tanker", "export_container",
                      "export_general_cargo", "export_roro", "portcalls",
                      "ingested_at"))
})

test_that("parse_portwatch_features parses the real Daily_Ports_Data schema", {
  body <- jsonlite::toJSON(list(
    features = list(
      list(attributes = list(
        date                 = "2024-01-01",
        portid               = "port955",
        portname             = "Port Hedland",
        ISO3                 = "AUS",
        export_dry_bulk      = 1341863L,
        export_tanker        = 0L,
        export_container     = 0L,
        export_general_cargo = 0L,
        export_roro          = 0L,
        portcalls            = 5L
      )),
      list(attributes = list(
        date                 = "2024-01-02",
        portid               = "port280",
        portname             = "Darwin",
        ISO3                 = "AUS",
        export_dry_bulk      = 0L,
        export_tanker        = 74856L,
        export_container     = 0L,
        export_general_cargo = 0L,
        export_roro          = 0L,
        portcalls            = 2L
      ))
    )
  ), auto_unbox = TRUE)

  out <- parse_portwatch_features(as.character(body))
  expect_equal(nrow(out), 2)
  expect_equal(out$portid,   c("port955", "port280"))
  expect_equal(out$portname, c("Port Hedland", "Darwin"))
  expect_equal(out$export_dry_bulk, c(1341863L, 0L))
  expect_equal(out$export_tanker,   c(0L, 74856L))
  expect_s3_class(out$obs_date, "Date")
  expect_equal(out$obs_date, as.Date(c("2024-01-01", "2024-01-02")))
})

test_that("parse_portwatch_features tolerates epoch-ms date encoding", {
  # Some ArcGIS layers return `date` as epoch-ms (esriFieldTypeDate),
  # others as ISO string (esriFieldTypeDateOnly). We need to handle both.
  body <- jsonlite::toJSON(list(
    features = list(list(attributes = list(
      date = 1704067200000,  # 2024-01-01 UTC in ms
      portid = "port955", portname = "Port Hedland", ISO3 = "AUS",
      export_dry_bulk = 1000L, export_tanker = 0L,
      export_container = 0L, export_general_cargo = 0L,
      export_roro = 0L, portcalls = 1L
    )))
  ), auto_unbox = TRUE)
  out <- parse_portwatch_features(as.character(body))
  expect_equal(out$obs_date, as.Date("2024-01-01"))
})

test_that("derive_portwatch_commodity_rows routes vessel types correctly", {
  wide <- tibble::tibble(
    obs_date             = as.Date(c("2024-01-01", "2024-01-01",
                                      "2024-01-01", "2024-01-01", "2024-01-01")),
    portid               = c("port955", "port816", "port280", "port174", "port937"),
    portname             = c("Port Hedland", "Newcastle", "Darwin",
                              "Brisbane", "Port Bonython"),
    export_dry_bulk      = c(1000L, 500L, 0L, 0L, 0L),
    export_tanker        = c(0L, 0L, 700L, 0L, 200L),
    export_container     = c(0L, 0L, 0L, 200L, 0L),
    export_general_cargo = c(0L, 0L, 0L, 0L, 0L),
    export_roro          = c(0L, 0L, 0L, 0L, 0L),
    portcalls            = c(5L, 3L, 2L, 4L, 1L),
    ingested_at          = Sys.time()
  )
  ports_meta <- tibble::tibble(
    port_name       = c("Port Hedland", "Newcastle", "Darwin", "Brisbane"),
    commodity_class = c("iron_ore",     "coal",      "lng",    "other")
  )

  out <- derive_portwatch_commodity_rows(
    wide, ports_meta,
    lng_ports = c("Darwin", "Dampier", "Gladstone", "Gorgon LNG", "Onslow")
  )

  # iron_ore dry_bulk at Port Hedland, coal dry_bulk at Newcastle, lng
  # tanker at Darwin. Brisbane container + Port Bonython tanker are both
  # dropped (container has no commodity mapping; tanker at non-LNG port
  # is filtered).
  expect_equal(nrow(out), 3)
  expect_setequal(out$commodity, c("iron_ore", "coal", "lng"))
  expect_equal(out$tonnage[out$commodity == "iron_ore"], 1000)
  expect_equal(out$tonnage[out$commodity == "coal"],      500)
  expect_equal(out$tonnage[out$commodity == "lng"],       700)
})

test_that("derive_portwatch_commodity_rows drops tanker at non-LNG ports", {
  wide <- tibble::tibble(
    obs_date             = as.Date("2024-01-01"),
    portid               = "port937",
    portname             = "Port Bonython",
    export_dry_bulk      = 0L, export_tanker = 500L,
    export_container     = 0L, export_general_cargo = 0L,
    export_roro          = 0L, portcalls = 1L,
    ingested_at          = Sys.time()
  )
  ports_meta <- tibble::tibble(port_name = character(),
                                commodity_class = character())
  out <- derive_portwatch_commodity_rows(
    wide, ports_meta,
    lng_ports = c("Darwin", "Dampier", "Gladstone", "Gorgon LNG", "Onslow")
  )
  expect_equal(nrow(out), 0)
})

test_that("derive_portwatch_commodity_rows drops dry_bulk at unknown port", {
  wide <- tibble::tibble(
    obs_date             = as.Date("2024-01-01"),
    portid               = "port999",
    portname             = "Some Random Port",
    export_dry_bulk      = 100L, export_tanker = 0L,
    export_container     = 0L,   export_general_cargo = 0L,
    export_roro          = 0L,   portcalls = 1L,
    ingested_at          = Sys.time()
  )
  ports_meta <- tibble::tibble(port_name = character(),
                                commodity_class = character())
  out <- derive_portwatch_commodity_rows(wide, ports_meta,
                                          lng_ports = character(0))
  expect_equal(nrow(out), 0)
})

test_that("derive_portwatch_commodity_rows drops zero-tonnage rows", {
  wide <- tibble::tibble(
    obs_date             = as.Date("2024-01-01"),
    portid               = "port955", portname = "Port Hedland",
    export_dry_bulk      = 0L, export_tanker = 0L, export_container = 0L,
    export_general_cargo = 0L, export_roro = 0L, portcalls = 0L,
    ingested_at          = Sys.time()
  )
  ports_meta <- tibble::tibble(port_name = "Port Hedland",
                                commodity_class = "iron_ore")
  out <- derive_portwatch_commodity_rows(wide, ports_meta)
  expect_equal(nrow(out), 0)
})

test_that("fetch_portwatch_tonnage falls back to cache on HTTP failure", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse_dir  = file.path(tmp, "warehouse"),
      cache          = file.path(tmp, "cache"),
      logs           = file.path(tmp, "logs"),
      ports_metadata = testthat::test_path("..", "..", "inst", "extdata",
                                            "ports_metadata.csv")
    ),
    sample = list(train_start = "2019-01-01"),
    portwatch = list(
      base_url    = "https://example.invalid/fs/0",
      countries   = "AUS",
      page_size   = 2000,
      retry       = list(max_attempts = 1, backoff_seconds = 0)
    ),
    logging = list(level = "WARN")
  )
  init_logger(cfg)
  warehouse_init_schema(cfg)

  # Cache holds a wide-schema tibble (the caller then runs
  # derive_portwatch_commodity_rows on it).
  seed <- tibble::tibble(
    obs_date             = as.Date("2024-01-01"),
    portid               = "port955",
    portname             = "Port Hedland",
    export_dry_bulk      = 1000L,
    export_tanker        = 0L,
    export_container     = 0L,
    export_general_cargo = 0L,
    export_roro          = 0L,
    portcalls            = 5L,
    ingested_at          = Sys.time()
  )
  cache_write(cfg, "portwatch", "daily_ports_data", seed)

  # example.invalid doesn't resolve -- fetcher errors, with_cache falls
  # back to the seeded cache above. Derivation then maps the Port
  # Hedland dry_bulk row to iron_ore.
  out <- fetch_portwatch_tonnage(cfg, cfg$paths$warehouse_dir)
  expect_equal(nrow(out), 1)
  expect_equal(out$commodity, "iron_ore")
  expect_equal(out$tonnage, 1000)
})
