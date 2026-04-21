# resourcetracker

Nowcasts ABS 5302.0 quarterly real goods exports for Australia from
IMF PortWatch AIS tonnage, ABS 5368.0 monthly merchandise trade, and
FRED commodity prices. Bridge regressions per commodity (iron ore,
coal, LNG, residual "other") feed a quarterly aggregate with bootstrap
uncertainty bands that shrink as the current quarter is observed.

- Methodology: [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md)
- Brief: [`PROJECT_BRIEF.txt`](PROJECT_BRIEF.txt)

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| R | ≥ 4.2 | `Depends` in `DESCRIPTION` |
| FRED API key | free | Register at <https://fred.stlouisfed.org/docs/api/api_key.html> |

No compiled / DLL dependencies beyond what a stock CRAN R install
provides — the pipeline runs on locked-down work machines that block
DuckDB, X-13-ARIMA-SEATS, and similar native libraries.

## One-time setup

```r
install.packages(c(
  "dplyr", "fredr", "fs", "httr2", "jsonlite", "lubridate", "purrr",
  "readabs", "readr", "rlang", "rmarkdown", "stringr", "tibble", "tidyr"
))
# Optional (briefing + dashboard + tests):
install.packages(c("ggplot2", "knitr", "shiny", "testthat", "withr"))

file.copy(".Renviron.example", ".Renviron")
# Edit .Renviron, set FRED_API_KEY=..., save.
```

## Running the pipeline

```bash
Rscript run.R               # normal run, skip steps whose rds is up-to-date
Rscript run.R --force       # force rerun of every step
Rscript run.R --no-report   # skip the briefing HTML render
```

What it does (see [`run.R`](run.R)):

1. Loads `config.R` and initialises the dated file logger (`logs/YYYY-MM-DD.log`).
2. Creates the rds-backed warehouse under `data/warehouse/`.
3. Loads port metadata + SITC crosswalk.
4. Pulls PortWatch tonnage, ABS 5368.0 / 5302.0, and FRED prices —
   each with retry + RDS cache fallback under `data/cache/<source>/`.
5. Builds the monthly feature panel, STL-adjusts tonnage for seasonality.
6. Fits bridge regressions (log-levels + AR(1) + Newey-West HAC SEs via
   the local `nw_vcov()`), runs a walk-forward backtest vs a
   seasonal-random-walk benchmark.
7. Computes the running nowcast with 80 / 95 bootstrap bands, flags
   anomalies, appends a row to `mart_nowcast_history`.
8. Writes four CSVs to `outputs/` and renders the briefing to
   `reports/briefing/briefing.html`.

Total runtime target: well under a minute on a warm cache.

## Dashboard

```r
shiny::runApp("reports/dashboard")
```

The dashboard reads `outputs/*.csv` and rds tables from
`data/warehouse/`; always launch from the repo root.

## Tests

```r
testthat::test_dir("tests/testthat")
```

## Directory layout

```
resourcetracker/
├── R/                       # package source
├── inst/extdata/            # ports_metadata.csv, sitc_crosswalk.csv
├── tests/testthat/          # unit + integration tests
├── reports/
│   ├── briefing/briefing.Rmd
│   └── dashboard/app.R
├── run.R                    # orchestrator (replaces _targets.R)
├── config.R                 # paths, series IDs, SITC map, bootstrap
├── DESCRIPTION / NAMESPACE  # package metadata
├── data/                    # gitignored -- warehouse + cache
├── outputs/                 # gitignored -- run artefacts
├── logs/                    # gitignored -- dated run logs
└── docs/METHODOLOGY.md      # econometric writeup
```

## Troubleshooting

**`Error: FRED_API_KEY not set` and a stale cache warning.**
Fill in `.Renviron`, or accept that FRED data is frozen at the last
successful pull.

**PortWatch fetch returns 0 rows.**
The default FeatureServer layer ID in `config.R` is a Phase-1
placeholder and must be replaced with the live IMF PortWatch endpoint.
Override via `Sys.setenv(PORTWATCH_BASE_URL = "https://.../FeatureServer/<id>")`
or edit `config.R` directly. The JSON parser isolates field-name
handling in `parse_portwatch_features()` — extend the `pick()`
fallback list if IMF renames columns.

**Briefing render fails with `pandoc version ... not found`.**
Install pandoc (ships with RStudio; `rmarkdown::pandoc_available()`
tells you whether it's on PATH). The CSV artefacts still land even if
the render step fails.

**`no cache available` error.**
First run with no network and no seeded cache. Run once with
connectivity so each source populates its cache, then offline runs
will fall back cleanly.

## Data ethics & redistribution

PortWatch, ABS, and FRED are free public data sources. Check each
provider's terms if you plan to redistribute cached raw extracts.
