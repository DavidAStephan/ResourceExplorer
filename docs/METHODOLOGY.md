# Methodology

This document is the econometric writeup for `resourcetracker`. If
you're reading source to understand a modelling choice, start here.

## 1. Goal

Nowcast **quarterly physical-tonnage exports** of two Australian
commodities — iron ore and coal — from IMF PortWatch AIS daily tonnage
plus the most-recent DISR Resources & Energy Quarterly (REQ) Table 16
release, well before the next DISR publication.

The headline success metric is RMSE ≥ 30% below a seasonal-random-walk
benchmark on 2024+ out-of-sample quarters. Both commodities currently
beat that target by a comfortable margin (see § 6).

**Scope note.** The project was originally framed around ABS 5302.0
chain-volume goods credits with three commodities + a residual bucket.
That scope was narrowed on 2026-04-21 after a backtest showed:

1. LNG tanker tonnage from PortWatch has near-zero correlation with
   ABS LNG export volumes at quarterly grain (LNG flows are
   contract-driven, not vessel-call-driven).
2. The residual "other" bucket added more variance than signal.

Iron ore + coal account for ~65% of Australian resource exports by
value and ~85% by volume, so the narrower scope still covers the
bulk of the question being asked.

## 2. Data

| Source | Series | Frequency | Role |
|---|---|---|---|
| IMF PortWatch (ArcGIS FeatureServer) | AUS port AIS tonnage by commodity | Daily | RHS indicator |
| DISR Resources & Energy Quarterly, Table 16 (kt / Mt) | Per-commodity physical export volume | Quarterly | **LHS target** |
| World Bank Pink Sheet (xlsx) | Iron-ore CFR spot, Newcastle thermal coal | Monthly | RHS (price_aug) |
| FRED (Federal Reserve Bank of St. Louis API) | `CHNLOLITOAASTSAM` (OECD China CLI) → iron_ore; `XTEXVA01CNM667S` (China exports value) → coal_thermal | Monthly | RHS (demand_aug) |
| `inst/extdata/ports_metadata.csv` | Hand-curated port → commodity-bucket map | Static | Joins PortWatch ports to commodity buckets |

PortWatch, DISR, and the World Bank Pink Sheet are public endpoints
that require no key. FRED requires a free API key — set via the
`FRED_API_KEY` env var (see `.Renviron.example`). When the FRED key is
unset the pipeline still runs end-to-end; the bench just drops the
`demand_aug` candidate per commodity automatically via
`fit_bridge_one`'s NA / min_n guardrails.

**PortWatch processing.** The IMF FeatureServer exposes raw daily
export tonnage by vessel type per port. We attach each port to its
commodity bucket via the static metadata file, then sum
`export_dry_bulk` for iron-ore and coal ports. Tanker tonnage at the
LNG-whitelisted ports is routed to a `lng` bucket at ingestion but is
not consumed downstream (legacy from the original scope; kept for
auditability).

## 3. Feature panel

`build_features()` produces one row per (commodity, quarter_end) with
the following key columns:

| column | meaning |
|---|---|
| `volume_Mt` | LHS target — DISR REQ T16 physical Mt |
| `log_volume` | log of LHS |
| `log_volume_lag4` | year-ago LHS (seasonal anchor) |
| `yoy_log_volume` | YoY-Δ of LHS (used by the `bojo` spec) |
| `tonnage_m1`, `tonnage_m2`, `tonnage_m3` | PortWatch tonnage in each month of the quarter |
| `yoy_log_tonnage` | YoY-Δ of total quarterly PortWatch tonnage |
| `yoy_log_tonnage_m1` … `_m3` | YoY-Δ of each monthly position |

**No explicit seasonal adjustment is applied.** The Δ_4 transforms on
the RHS (and `bojo`'s LHS) strip deterministic seasonality
mechanically. STL / X-13 functions exist in `R/seasonal_adjust.R` but
are no longer called by the bridge; they're kept for ad-hoc
exploratory use.

This choice matches the closest-analogue literature: Furukawa & Hisano
(2022, BoJ WP 22-E-19) and Del-Rosario & Quách (2024, AMRO WP) both
use YoY differencing rather than pre-SA when nowcasting trade from
AIS-derived indicators, on samples comparable in length to ours.

## 4. Bridge specifications — candidate bench

Three candidate specs are fit for each commodity at every refit (live
and inside each backtest quarter). Per-commodity production choice is
made by walk-forward backtest RMSE (§ 6).

### 4.1 Aggregate

Free `β_lag4`, single quarterly tonnage regressor.

$$
\log V_{c,Q} \;=\; \beta_0
  \;+\; \beta_T \, \Delta_{Q,Q-4}\log T_{c,Q}
  \;+\; \beta_4 \log V_{c,Q-4}
  \;+\; \varepsilon_{c,Q}
$$

### 4.2 Unrestricted MIDAS (U-MIDAS)

Replaces the single Δ_4 log T with three free monthly betas:

$$
\log V_{c,Q} \;=\; \beta_0
  \;+\; \sum_{m=1}^{3} \beta_{m} \, \Delta_{Q,Q-4}\log T_{c,Q,m}
  \;+\; \beta_4 \log V_{c,Q-4}
  \;+\; \varepsilon_{c,Q}
$$

Three extra parameters; useful when within-quarter timing carries
signal (e.g., iron ore: the first month of a quarter is the strongest
indicator of the quarter's total).

### 4.3 BoJ-style (`bojo`)

The literature standard from Furukawa & Hisano (2022) and Del-Rosario
& Quách (2024). Pure YoY-on-YoY, equivalent to imposing `β_4 = 1` on
the aggregate spec.

$$
\Delta_{Q,Q-4}\log V_{c,Q} \;=\; \beta_0
  \;+\; \beta_T \, \Delta_{Q,Q-4}\log T_{c,Q}
  \;+\; \varepsilon_{c,Q}
$$

Two parameters total. Beats the others when `β_4` is statistically
indistinguishable from 1 (our iron-ore case, see § 6).

### 4.4 Why these three

Our specs are nested: `bojo ⊂ aggregate ⊂ midas` in terms of
parameter count. The bench lets the data tell us which level of
flexibility is justified, with a Wald test (`β_lag4 = 1`) reported in
`bridge_diagnostics.csv` as a complementary check.

### 4.5 Augmented specs (`lagged`, `price_aug`, `demand_aug`)

Three extension candidates extend the aggregate spec with one
additional regressor each, testing whether information beyond
current-quarter PortWatch tonnage adds predictive power:

- **`lagged`** — adds `yoy_log_tonnage_lag1` (one-quarter-lagged YoY
  tonnage). Tests the Adland-Jia-Strandenes (2017) hypothesis that
  AIS leads customs-cleared trade by several weeks.
- **`price_aug`** — adds `yoy_log_price` from the World Bank Pink
  Sheet (iron-ore CFR spot for `iron_ore`; Newcastle thermal coal
  for both coal sub-commodities). Tests whether the price signal
  carries information beyond what tonnage already implies.
- **`demand_aug`** — adds `yoy_log_demand_*` from FRED. iron_ore picks
  up the OECD Composite Leading Indicator for China; coal_thermal
  picks up China's monthly merchandise exports value. Adds a
  *demand-side* regressor with an independent release calendar from
  PortWatch, on the Stock-Watson (2004) rationale that forecast-
  combination gains are largest when candidates draw on different
  information. `coal_met` deliberately has no FRED series in this
  pass — overfit risk at N ≈ 23 / k. The RHS is auto-pruned
  per commodity in `fit_bridge_one`: each commodity gets only the
  series mapped to it, and a commodity with no series at all is
  skipped automatically.

When an augmented spec wins production for a commodity, the briefing's
production-equation section renders with the augmented coefficients;
when it doesn't, the spec stays in the bench as diagnostic info via
the OOS leaderboard (same pattern across all augmentations).

## 5. Forecast combination

In addition to the three single-spec candidates, two combinations are
computed at backtest time:

- **`equal_avg`** — arithmetic mean of the three single-spec point
  forecasts at each (commodity, quarter).
- **`inv_mse`** — weighted mean, weights ∝ `1 / RMSE_oos²` over the
  full backtest sample.

The "forecast combination puzzle" (Stock & Watson 2004; Aiolfi &
Timmermann 2006; Timmermann 2006 Handbook of Forecasting) is that
equal weights often beat more sophisticated weighting schemes
out-of-sample, especially at small N. We report both so the gap is
visible. Both go through the same backtest and OOS-RMSE machinery as
the single specs and compete on equal footing for the per-commodity
production slot.

## 6. Production model selection

For each commodity, the production-deployed model is the single best
candidate or combination by walk-forward backtest RMSE. The choice is
recorded in `bridge_diagnostics.csv` (`production_choice = TRUE` for
the chosen row) and surfaced with a ★ in the briefing's diagnostics
table.

Current (2026-05-19) production picks and walk-forward skill:

| commodity | production_spec | OOS RMSE / naive | β_lag4 (p-val if applicable) |
|---|---|---|---|
| iron_ore | `bojo` (β_4 imposed = 1) | 0.78 | aggregate p = 0.36, midas p = 0.71 → restriction not rejected |
| coal | `aggregate` (β_4 free, ≈ 0.73) | 0.50 | p < 0.001 → restriction rejected; mean reversion is real |

Both clear the project's "≥ 30% RMSE reduction vs naive" target.

## 7. Estimation

All specs are OLS with Newey-West HAC standard errors at
`lag = cfg$bridge$hac_lag` (default 1, appropriate for quarterly data
with one persistence-absorbing term). HAC computation is the local
`nw_vcov()` in `R/hac.R` — Bartlett kernel, no pre-whitening,
matches `sandwich::NeweyWest(..., prewhite = FALSE)` to machine
precision.

**Why no log price.** The target is *physical tonnage* in Mt. Price
effects are stripped on the LHS by construction. Adding `log P` on
the RHS would fit a coefficient the target has no mechanical link to.

**Guardrails** (see `R/bridge.R::fit_bridge_one`):

- Commodities with fewer than `cfg$bridge$min_n` training quarters
  are skipped.
- Any regressor (or LHS) with near-zero variance skips with a warning.
- HAC failures (rare — usually singular design) skip.

## 8. Running nowcast — partial-quarter logic

Given current date `t` in quarter `Q` with months `m_1, m_2, m_3` and
`effective_today = min(t, max(obs_date))` (the PortWatch coverage may
lag the calendar by 7–14 days):

- **Completed months relative to effective_today** (`month_end ≤ effective_today`):
  use observed PortWatch monthly tonnage directly.
- **Current month** (contains `effective_today`): scale partial-month
  observed tonnage by the commodity's 2019+ day-of-month cumulative
  share at the *data's* `d = effective_today - m_floor + 1`. NOT the
  calendar `Sys.Date()` — that was a bug fixed in May 2026 (issue: the
  nowcast underestimated by 10–20% because we divided observed
  tonnage by an expected share computed for days PortWatch hadn't
  reached). A `sanity_clip_partial()` safety net falls back to the
  seasonal-norm estimate if the scale-up lands more than 3× off.
- **Future months relative to effective_today**: use `seasonal_avg × pace`,
  where `pace` is the last completed month's tonnage over its own
  seasonal average. A pickup in recent pace carries forward.

The three hatted monthly tonnages enter the prediction frame; the
production model (single spec or combination) computes the
point-estimate log volume; `exp()` returns the Mt-scale headline.

## 9. Uncertainty bands

Residual bootstrap, `B = cfg$nowcast$bootstrap_reps` (default 1000):

1. For the production model, sample one residual `ε^(b)` with
   replacement.
2. Scale by `√(1 - share_observed)` where `share_observed` is the
   fraction of the *quarter* elapsed (calendar-based). Bands collapse
   as the quarter fills in.
3. Combined production residuals (when the production choice is
   `equal_avg` or `inv_mse`) are computed in log V space across
   components via `combined_log_residuals()`. Single-spec choices
   reuse the lm residuals directly. Bootstrap is i.i.d. resampling
   from this residual vector.
4. `V^(b) = exp(point_log + ε^(b) · scale)` per draw.
5. Bands: 10th/90th percentile = 80% CI; 2.5th/97.5th = 95% CI.

A fixed seed (`cfg$nowcast$seed`, default `20260419`) makes bands
identical across reruns of identical inputs.

## 10. Backtest

- **Window start:** 2019-Q1 (PortWatch's earliest reliable coverage).
- **Validation start:** `cfg$sample$valid_start` (default 2024-Q1).
- **Scheme:** expanding window. For each validation quarter `Q`,
  refit *every candidate spec* (and the combinations) on data through
  `Q - one quarter`, predict `Q`, record per-spec error.

Per-spec and combination OOS RMSE is reported in
`bridge_diagnostics.csv` alongside the in-sample fit. The
production-choice mechanic in § 6 reads this table.

## 11. Anomaly detection (briefing only)

For each (port, commodity): compute a seasonal daily norm by pooling
training-window observations over a ±7-day window around each day of
year. Z-score the last 28 observed days; flag `|z| > 2`. Surfaces in
the briefing as "departures from seasonal norm".

## 12. Known limitations / future work

1. **Coal thermal/metallurgical combined.** DISR rows 47 + 48 are
   summed into a single `coal` series. Different price drivers
   (steelmaking demand vs power-generation demand) and the methodology
   review of May 2026 flagged splitting as a worthwhile extension.
2. **YoY-differencing is sensitive to one-off year-ago shocks.** A
   typhoon-disrupted 2025-Q1 inflates 2026-Q1's YoY growth
   artificially. Acceptable trade-off given our sample size; flagged
   in the literature (Adland, Jia & Strandenes 2017).
3. **Cross-component residual correlation in combinations** is not
   explicitly modelled. Bootstrap uses i.i.d. resampling of the
   combined residual series; understates correlation only when
   draws are joint — for level forecasts this is a second-order issue.
4. **No structural-break testing.** The AIS↔DISR relationship can
   shift (composition effects, port congestion regimes, etc.). A
   `strucchange::Fstats()` pass per commodity is on the follow-up list.
5. **Deflator forecast = trailing 4-quarter mean.** Vestigial from
   the ABS-chain-volume era; not used in the current physical-tonnage
   target. Documented here for archival reasons.

## 13. Reproducibility

`cfg$nowcast$seed` (default `20260419`) controls bootstrap draws.
The pipeline writes every external fetch to `mart_ingest_runs` with
`{run_id, source, started_at, finished_at, rows_written, status}`
for an after-the-fact audit trail. Run history (one row per nowcast
per commodity per run) lives in `mart_nowcast_history`, both
persisted to the `data` branch by the weekly Actions cron.

## 14. References

- Furukawa, K. & Hisano, R. (2022). *A Nowcasting Model of Exports
  Using Maritime Big Data.* Bank of Japan WP 22-E-19.
- Del-Rosario, D. & Quách, V. A. (2024). *Nowcasting ASEAN+3 Goods
  Exports: Bridge and Machine Learning Models and Shipping "Big
  Data".* AMRO WP.
- Cerdeiro, D., Komaromi, A., Liu, Y. & Saeed, M. (2020). *World
  Seaborne Trade in Real Time.* IMF WP 20/57.
- Adland, R., Jia, H. & Strandenes, S. P. (2017). *Are AIS-based
  trade volume estimates reliable? The case of crude oil exports.*
  Maritime Policy & Management 44(5).
- Bates, J. M. & Granger, C. W. J. (1969). *The combination of
  forecasts.* Operational Research Quarterly 20(4).
- Stock, J. H. & Watson, M. W. (2004). *Combination forecasts of
  output growth in a seven-country data set.* J. Forecasting 23.
- Aiolfi, M. & Timmermann, A. (2006). *Persistence in forecasting
  performance and conditional combination strategies.* J.
  Econometrics 135.
- Timmermann, A. (2006). *Forecast combinations.* In Handbook of
  Economic Forecasting, vol. 1.
- Baffigi, A., Golinelli, R. & Parigi, G. (2002). *Real-time GDP
  forecasting in the euro area.* Banca d'Italia Temi 456.
