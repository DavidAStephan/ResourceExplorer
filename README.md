# resourcetracker

**Weekly nowcast of Australian iron-ore and coal exports, before the
official statistics drop.** The Department of Industry publishes
physical-tonnage exports quarterly with a ~5-week lag. This project
estimates the current quarter's volume right now, using ship-movement
data, and republishes every Tuesday.

> 📊 **[Read the latest nowcast →](https://davidastephan.github.io/ResourceExplorer/)**

### If you just landed here

- **What you get:** a number ("iron ore: 236 Mt, 80% CI 232–239") for
  the current quarter and the next one, plus the model's track record
  on prior quarters. Updated weekly.
- **How:** [IMF PortWatch](https://portwatch.imf.org/) gives daily
  ship-tonnage by port from AIS. A bridge regression maps that to
  [DISR REQ Table 16](https://www.industry.gov.au/publications/resources-and-energy-quarterly)
  physical export volumes. Bootstrap bands shrink as the quarter
  fills in. Full derivation in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).
- **Who it's for:** anyone who wants a real-time read on Australian
  bulk-commodity exports — analysts, journalists, traders, the
  curious. No subscription, no signup.
- **Why it works:** ~85% of Australian resource exports by volume go
  on ships visible in public AIS data. Year-on-year changes in port
  tonnage track year-on-year changes in DISR's reported volumes
  closely enough to nowcast at ≥30% RMSE reduction vs a seasonal
  random walk.

### Quick links

- **Live nowcast:** <https://davidastephan.github.io/ResourceExplorer/>
- **Programmatic feed:** [`/data/outputs.json`](https://davidastephan.github.io/ResourceExplorer/data/outputs.json) (schema: [`docs/OUTPUTS_JSON.md`](docs/OUTPUTS_JSON.md))
- **Methodology:** [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md)
- **Roadmap / open items:** [`docs/ROADMAP.md`](docs/ROADMAP.md)
- **Original brief:** [`PROJECT_BRIEF.txt`](PROJECT_BRIEF.txt)

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| R | ≥ 4.2 | `Depends` in `DESCRIPTION` |

No API keys are required: PortWatch is a public ArcGIS FeatureServer
and the DISR REQ historical workbook is a public xlsx. No compiled /
DLL dependencies beyond a stock CRAN R install.

## One-time setup

```r
install.packages(c(
  "curl", "dplyr", "fs", "ggplot2", "httr2", "jsonlite", "lubridate",
  "purrr", "readr", "readxl", "rlang", "rmarkdown", "stringr",
  "tibble", "tidyr"
))
# Optional (tests):
install.packages(c("knitr", "testthat", "withr"))
```

## Running the pipeline

```bash
Rscript run.R               # normal run, skip steps whose rds is up-to-date
Rscript run.R --force       # force rerun of every step
Rscript run.R --no-report   # skip the briefing HTML render
Rscript run.R --ci          # exit non-zero if every external fetch landed on stale cache
```

What it does (see [`run.R`](run.R)):

1. Loads `config.R` and initialises the dated file logger (`logs/YYYY-MM-DD.log`).
2. Creates the rds-backed warehouse under `data/warehouse/`.
3. Loads `inst/extdata/ports_metadata.csv`.
4. Pulls PortWatch daily tonnage and the DISR REQ historical workbook,
   each with retry + RDS cache fallback under `data/cache/<source>/`.
5. Builds the monthly feature panel (`build_features`).
6. Fits per-commodity bridge regressions (log-levels + AR(1) +
   Newey-West HAC SEs via the local `nw_vcov()`), runs a walk-forward
   backtest vs a seasonal-random-walk benchmark.
7. Computes the running nowcast with 80 / 95 bootstrap bands, flags
   anomalies, appends a row to `mart_nowcast_history`.
8. Writes four CSVs to `outputs/` and renders the briefing to
   `reports/briefing/briefing.html`.

Total runtime target: well under a minute on a warm cache.

## Tests

```r
testthat::test_dir("tests/testthat")
```

## Operations: weekly automated run

The pipeline runs every **Tuesday at 09:00 AEST** via
[`.github/workflows/weekly.yml`](.github/workflows/weekly.yml). It can
also be triggered manually from the Actions tab (`workflow_dispatch`).
Each run publishes to <https://davidastephan.github.io/ResourceExplorer/>
(bookmark `latest.html` for the current week; `history/YYYY-MM-DD.html`
for any previous week).

| Concern | Where it lives |
|---|---|
| Schedule | `cron: "0 23 * * 1"` (UTC) in the workflow |
| Persistent state | `data` branch — warehouse + cache + report archive |
| Published report | GitHub Pages: `latest.html` plus a dated `history/` |
| Failure alert | Auto-opened issue labelled `weekly-failure`; closes itself on next green run |
| Run logs | Per-run artifact `nowcast-logs-<run_id>`, 30-day retention |

**How state persists.** The workflow clones the `data` branch into a
side directory, copies its `data/` tree into the workspace, runs the
pipeline (which appends to `mart_nowcast_history.rds`), and force-pushes
the updated state back. The `data` branch is *not* a development
branch — treat it as artefact storage; never base a PR on it.

**Forcing a re-run.** Open the Actions tab → `weekly-nowcast` →
*Run workflow*. The same path also re-renders the report and re-deploys
to Pages, so it's the fix for "the published page is stale".

**Silent staleness guard.** `run.R --ci` exits non-zero if every
external fetch on a given run landed on the stale-cache fallback. The
workflow propagates that failure to the issue tracker, so we never
quietly publish last week's numbers as this week's.

## Directory layout

```
resourcetracker/
├── R/                       # package source
├── inst/extdata/            # ports_metadata.csv
├── tests/testthat/          # unit + integration tests
├── reports/
│   ├── briefing/briefing.Rmd
│   └── technical_note/      # methodology write-up
├── run.R                    # orchestrator (replaces _targets.R)
├── config.R                 # paths, DISR row map, bootstrap config
├── DESCRIPTION / NAMESPACE  # package metadata
├── data/                    # gitignored -- warehouse + cache
├── outputs/                 # gitignored -- run artefacts
├── logs/                    # gitignored -- dated run logs
└── docs/METHODOLOGY.md      # econometric writeup
```

## Troubleshooting

**PortWatch fetch fails with "0 rows (likely rate-limited)".**
The IMF ArcGIS FeatureServer occasionally returns HTTP 200 with a JSON
`{"error":...}` body under load; `make_request()` now treats those as
retriable, so a transient failure should self-recover on the next run.
If repeated runs return 0 rows, confirm the FeatureServer URL in
`config.R` still resolves and the `ISO3 IN ('AUS')` filter still
matches the live schema (fields are listed at
`https://services9.arcgis.com/weJ1QsnbMYJlCHdG/ArcGIS/rest/services/Daily_Ports_Data/FeatureServer/0?f=json`).

**Briefing render fails with `pandoc version ... not found`.**
Install pandoc (ships with RStudio; `rmarkdown::pandoc_available()`
tells you whether it's on PATH). The CSV artefacts still land even if
the render step fails.

**`no cache available` error.**
First run with no network and no seeded cache. Run once with
connectivity so each source populates its cache; offline runs then
fall back cleanly.

## Data ethics & redistribution

IMF PortWatch and DISR are free public data sources. Check each
provider's terms if you plan to redistribute cached raw extracts.
