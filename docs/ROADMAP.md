# Roadmap

Living document of follow-up work, ordered by ROI. Tiers 1, 2, 3, and 4
from the 2026-05 review have all landed (see commit history + the
Completed section). Open items below are the next layer down — things
that would extend the system but aren't on the immediate path.

## Open / future

> **Detailed plans available:**
> - China demand indicator (the next-up item): [`docs/PLAN_CHINA_DEMAND.md`](PLAN_CHINA_DEMAND.md)
> - LNG re-scope (deferred indefinitely): [`docs/PLAN_LNG_AND_DEMAND.md`](PLAN_LNG_AND_DEMAND.md) § Plan A
>
> The notes below summarise; the plan docs are what to read before
> committing time.

### Deeper external demand signal

Tier 4 #1 shipped a World-Bank Pink Sheet price ingest + `price_aug`
candidate spec on 2026-05-21; the bench evaluated it at the next
weekly run. Result: price didn't beat tonnage-only specs for any
commodity (price_aug RMSE worse than `bojo` / `midas` / `aggregate`
across iron-ore, coal_met, coal_thermal). The framework still keeps it
in the bench so future shifts in the relationship are picked up
automatically.

What would actually move the needle is a *demand* indicator (not a
price), which is harder to ingest:

- **China crude steel production** (monthly, NBS-published, ~3-week
  lag). Direct iron-ore demand. No clean free API; would need
  scraping or a paid API.
- **China power generation** (monthly, NBS). Thermal coal demand.
  Same access constraint.
- **Baltic Dry Index** (daily). Dry-bulk shipping freight rate — a
  near-real-time market gauge of bulk demand. No public API; the
  data is paywalled.

Effort to add any one: ~1 day for ingestion (the slot in the bridge
bench already exists). Adding all three: ~3 days. Worth doing only
when there's a budget for a data subscription or someone wants to
maintain a scraper.

### LNG re-scope — final note

This is **deferred indefinitely**, not just unstarted.

The original 2026-04-21 finding stands: PortWatch tanker-tonnage at
LNG ports has near-zero correlation with ABS LNG export volumes at
quarterly grain. Australian LNG is contract-dominated — vessels arrive
on schedule regardless of spot-price dynamics, so tonnage is an output
of contracts rather than an indicator of them.

The plausible workaround would model LNG via AIS *destination-share*
(% of tanker tonnage routed to Japan / Korea / China each quarter),
since destinations encode the contract structure implicitly. But:

1. The IMF PortWatch FeatureServer we consume **doesn't expose
   destination at the daily-tonnage layer** — it gives port-day
   tonnage broken out by vessel type, without per-voyage routing.
2. To get destinations we'd need a different AIS data source
   (commercial — VesselFinder, Spire, Kpler, MarineTraffic), and that
   adds a paywalled dependency the project has deliberately avoided.

So LNG is not addressable within the current "free public data only"
constraint. If the constraint relaxes, the work is roughly:

- New ingest pulling per-vessel destination data
- Quarterly destination-share derivation per Australian LNG port
- New `lng_destshare` candidate spec
- ~2-3 weeks of dev + validation, not days

Until then, the iron-ore + coal_met + coal_thermal panel is the live
scope.

## Backlog — newly identified (2026-05-21 review)

Items surfaced by a fresh pass over the project after Tier 4 landed.
Eight of the ten items below landed on 2026-05-21 (see the Completed
section); two remain.

### 8. Multi-country extension *(not started)*

**Effort:** weeks. **Why:** IMF PortWatch covers global ports. Brazil
iron ore (Vale), Indonesia thermal coal, US LNG export terminals —
same methodology applies. Real capability expansion but a much bigger
project: needs a country-aware data model refactor (config, ports
metadata, DISR-equivalent target series per country), then
per-country bridges. Worth attempting only if there's appetite for
turning this into a multi-country product rather than a focused
Australia tool.

### 9. Conformal-prediction band recalibration *(not started, low priority)*

**Effort:** ~half day. **Why:** if calibration check (now shipped as
#3) shows the residual-bootstrap bands are miscalibrated, conformal
prediction is the principled fix — finite-sample coverage guarantees
the bootstrap doesn't provide. **Current status:** empirical coverage
on production picks is reasonably close to nominal
(iron_ore/bojo 0.71/0.86, coal_met/midas 0.86/1.00,
coal_thermal/bojo 0.86/0.86 at the 80/95% bands), so this isn't
urgent. Re-evaluate if a future production pick lands with materially
worse coverage. Some non-production specs *are* badly miscalibrated
(`coal_thermal/lagged` covers 0.29 at 80%); not load-bearing today
but worth keeping an eye on.

## Anti-list — things I'd recommend NOT doing

Documenting these so they don't quietly bubble up as "we should also…"
items in the future:

- **Don't redesign the Pages site again.** It's done; the design
  system is the current source of truth for the look. Subsequent
  changes should fit *into* the existing tokens (colours, spacing,
  components), not invent new ones.
- **Don't add ML / neural-net candidates.** At N ≈ 23 training
  quarters, anything more complex than the current linear bench will
  overfit. The combination bench already gives us the diversity the
  data can support.
- **Don't migrate the warehouse to DuckDB / Postgres.** The rds +
  `data` branch pattern is genuinely well-suited to this dataset
  size. The constraint that originally pushed away from DuckDB (work-
  laptop allowlist) is still real.
- **Don't add more candidate specs unless they bring new
  information.** A fourth variant on the same PortWatch signal
  (e.g. an Almon-polynomial MIDAS) won't help; an indicator from a
  different data source (Tier 4 #1) will.

## Maintenance

This file is hand-maintained. Mark items as done by moving them under a
"Completed" section at the bottom with a date, or by deleting them and
adding a one-liner to the relevant commit message.

## Completed

### 2026-05-21 (second batch)

Phase-1/2/3 backlog landed in one pass. The briefing now has five new
sections; `bridge_diagnostics.csv` and `nowcast_current.csv` each
gained columns; the Shiny dashboard was removed.

- **#1 Automated nowcast-vs-actual comparison.** New "Forecast vs
  actual — closed quarters" section in the briefing joins
  `mart_nowcast_history` (h = 0, latest pre-publication run within 42
  days of quarter close) against `raw_disr_req_quarterly` actuals, then
  reports per-quarter error and an MAE/MAPE/CI-hit-rate summary per
  commodity. Closes the validation loop the original
  `PROJECT_BRIEF.txt` asked for.
- **#2 Backtest visualization.** New "Backtest — every spec, every
  quarter" plot in the briefing showing DISR actuals (black) against
  every candidate spec's point forecast (production pick in blue, the
  rest faded). Production-pick justification visible at a glance
  alongside the diagnostics table.
- **#3 Coverage / calibration check.** New `R/calibration.R` with
  `backtest_coverage()` — reconstructs the 80/95% bootstrap bands at
  share_observed = 0 for each backtest quarter and reports empirical
  hit-rate per spec. Joined into `bridge_diagnostics.csv` as `n_oos`,
  `coverage_80`, `coverage_95`. New "Band calibration" section in the
  briefing. Production picks land near nominal.
- **#4 Anomaly section.** New "Flagged anomalies" block in the
  briefing showing top-5 |z|-score departures from the seasonal daily
  norm over the last 28 days, joined to `mart_dim_port` for
  human-readable port names where available.
- **#5 Shiny dashboard removed.** `reports/dashboard/app.R` deleted;
  `shiny` dropped from `DESCRIPTION` Suggests; references scrubbed
  from `README.md`, `docs/METHODOLOGY.md`, `R/anomalies.R`. The
  briefing is the canonical view.
- **#6 WoW decomposition / attribution.** New `R/attribution.R` with
  `decompose_nowcast()` — mechanically attributes each nowcast to
  V_{Q-4} + tonnage signal + model anchor adjustment + other
  regressors. Five new columns on `nowcast_current.csv`. "Why the
  nowcast says what it says" table renders under the headline cards.
  Implemented as a *level* decomposition (vs seasonal naive baseline)
  rather than the WoW state-tracking the brief originally implied —
  more durable and explainable without needing prior-run feature state.
- **#7 README polish.** "If you just landed here" intro at the top
  plus what / how / who / why bullets, plus a quick-links section
  pointing to the live page, the JSON feed, methodology, roadmap.
- **#10 `docs/OUTPUTS_JSON.md` schema doc.** Stability contract for
  the `resourcetracker.outputs.v1` JSON endpoint — every field
  documented with type / unit / semantics, an example payload, an
  additive-change-is-non-breaking guarantee, and a versioning policy.

### 2026-05-20

- **Tier 1 cleanups** (PR #12): tidyselect lint sweep, removed the
  vestigial LNG ingestion pathway, WoW delta + enriched archive table
  on the landing page, failure-issue body now includes the log tail.
- **Tier 2 research** (PR #13): coal split into `coal_met` +
  `coal_thermal` (separate bridges on shared PortWatch RHS), new
  `lagged` candidate spec (Adland-Jia-Strandenes 2017), Chow test for
  structural break at training-sample midpoint. Coal_met turned out to
  be the most predictable commodity in the panel (RMSE/naive 0.49,
  MIDAS wins).
- **run.R force-write bug** (PR #14): `--force` rerun used to recompute
  in memory but skip the rds write when the file already existed.
  Surfaced by the coal-split schema change. Fixed by always persisting
  when a step actually ran.

### 2026-05-21

- **Tier 3 operational hardening** (PR #15):
  - `renv.lock` committed; workflow restores via
    `r-lib/actions/setup-renv@v2`. Pipeline runtime + tests + check now
    pin to a single resolved package set across local and CI.
  - Graduated staleness signal: `run.R` writes `outputs/staleness.json`
    with days-since-last-fresh-fetch per source. The workflow opens /
    closes a soft `weekly-stale-source` issue when any source has been
    stale for more than 7 days. Independent of the hard `--ci` all-stale
    failure path.
  - New `.github/workflows/check.yml`: `R CMD check --no-manual` on PRs
    and pushes to main. 0 errors, 0 warnings; one informational NOTE
    about `ggplot2` / `stringr` being declared Imports but consumed via
    the briefing's separate rmarkdown render env (real runtime deps,
    just not visible to the checker).

- **Tier 4 extensions** (PR #19, #20, #21):
  - **Q+1 forecast**: `run_nowcast` takes a `horizon = c(0L, 1L)` arg;
    Q+1 row produced for each commodity using the seasonal-pace future-
    months extrapolation. Surfaced as a "Next-quarter outlook" section
    in the briefing + sub-line on each landing-card.
  - **`outputs.json` endpoint** at `/data/outputs.json`. Compact
    schema-versioned JSON summary for programmatic consumers: point +
    80/95 bands per (commodity × horizon), plus production spec and
    RMSE-vs-naive per pick.
  - **World Bank Pink Sheet ingestion + `price_aug` candidate spec**.
    Pulls the monthly Pink Sheet xlsx (no API key), aggregates to
    quarterly average, plumbs `yoy_log_price` through the feature
    panel, adds `price_aug` to `cfg$bridge$candidates`. The bench
    evaluated it against the existing candidates; price didn't win
    production for any commodity (iron_ore/price_aug RMSE 4.86 vs
    bojo 4.51; coal_met/price_aug 1.79 vs midas 1.10;
    coal_thermal/price_aug 3.03 vs bojo 2.21). Kept in the bench so
    the OOS leaderboard flags if/when the relationship shifts.
  - **LNG re-scope**: not shipped — final analysis in the body of this
    doc. Blocker is concrete (we don't have AIS destination data in
    the public PortWatch slice).
