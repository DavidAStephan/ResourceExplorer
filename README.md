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
| `renv` | latest | Installed once, locks all other deps |
| Quarto CLI | ≥ 1.4 | Needed to render the briefing — install from <https://quarto.org> |
| LaTeX | any | Needed for PDF output. `tinytex::install_tinytex()` works |
| FRED API key | free | Register at <https://fred.stlouisfed.org/docs/api/api_key.html> |

X-13-ARIMA-SEATS ships pre-built via the `x13binary` package — no
manual install needed.

---

## One-time setup

```r
# 1. Clone and enter the repo, then from R:
install.packages("renv")
renv::init()              # scans DESCRIPTION, installs everything
renv::restore()           # if renv.lock is committed

# 2. Secrets
file.copy(".Renviron.example", ".Renviron")
# Edit .Renviron, fill in FRED_API_KEY=..., save, then:
readRenviron(".Renviron")

# 3. Regenerate NAMESPACE from roxygen (only after editing R/)
devtools::document()
```

---

## Running the pipeline

```r
targets::tar_make()
```

What this does:

1. Loads `config.yml` and initialises the logger (`logs/YYYY-MM-DD.log`).
2. Creates `data/warehouse.duckdb` with `raw.*` and `mart.*` schemas.
3. Loads port metadata and the SITC crosswalk into the warehouse.
4. Pulls PortWatch tonnage, ABS 5368.0 / 5302.0, and FRED prices —
   each with retry + RDS cache fallback (`data/cache/<source>/…`).
5. Builds the monthly feature panel, X-13 seasonally adjusts tonnage.
6. Fits bridge regressions (log-levels + AR(1) + HAC SEs), runs the
   walk-forward backtest vs a seasonal-random-walk benchmark.
7. Computes the running nowcast with 80/95 bootstrap bands, flags
   anomalies, writes a row to `mart.nowcast_history`.
8. Writes the four CSV artefacts to `outputs/` and renders the
   Quarto briefing to `reports/briefing/briefing.{html,pdf}`.

Total runtime target: under 5 minutes on a warm cache.

### Run offline (with stale cache)

```r
targets::tar_make()   # same command; if a fetch fails, we use the
                      # last successful cache and tag the tibble
                      # with attr(x, "cache_status") = "stale".
```

### Inspect the DAG

```r
targets::tar_visnetwork()
```

---

## Running the dashboard

From the repo root:

```r
shiny::runApp("reports/dashboard")
```

The dashboard reads from `outputs/*.csv` and `data/warehouse.duckdb`
with paths hard-coded relative to the app directory — always launch
from the repo root.

---

## Tests

```r
devtools::test()             # full suite
devtools::test_active_file() # single file, from RStudio
devtools::check()            # R CMD check; zero errors expected
```

Tests that hit the real X-13 binary skip if `{seasonal}` isn't
available. HTTP-level tests use `{httptest2}` and ship with fixtures.

---

## Directory layout

```
resourcetracker/
├── R/                       # package source
├── inst/
│   ├── extdata/             # ports_metadata.csv, sitc_crosswalk.csv
│   └── sql/schema.sql       # DuckDB DDL (idempotent)
├── tests/testthat/          # unit + integration tests
├── reports/
│   ├── briefing/briefing.qmd
│   └── dashboard/app.R
├── _targets.R               # pipeline DAG
├── config.yml               # paths, series IDs, SITC map, bootstrap
├── DESCRIPTION / NAMESPACE  # package metadata
├── data/                    # gitignored — warehouse + cache
├── outputs/                 # gitignored — run artefacts
├── logs/                    # gitignored — dated run logs
└── docs/METHODOLOGY.md      # econometric writeup
```

---

## Troubleshooting

**`Error: FRED_API_KEY not set` and a stale cache warning.**
Either fill in `.Renviron` or accept that FRED data is frozen at the
last successful pull.

**PortWatch HTTP 404 on first run.**
The IMF occasionally moves the FeatureServer layer ID. Override via
`Sys.setenv(PORTWATCH_BASE_URL = "https://.../FeatureServer/<new-id>")`
or edit `config.yml`. The JSON parser isolates field-name handling in
`parse_portwatch_features()` — adjust the `pick()` fallback list if
the IMF renames columns.

**`quarto not found on PATH` warning.**
Install Quarto from <https://quarto.org>. The pipeline doesn't fail
without it — the CSV artefacts still land in `outputs/`, only the
briefing skips.

**X-13 fails on a commodity.**
X-13 refuses series shorter than 36 months. `x13_adjust()` falls back
to the raw series with a warning — check the log for which commodity.

**`LaTeX Error: File ... not found` during briefing render.**
Run `tinytex::install_tinytex()` once, then re-run `tar_make()`.

**`no cache available` error during `tar_make()`.**
First run, no network, and the cache is empty. Run once with a
connection to populate, then offline runs will work.

---

## Data ethics & redistribution

PortWatch, ABS, and FRED are free public data sources. Check each
provider's terms if you plan to redistribute cached raw extracts.
