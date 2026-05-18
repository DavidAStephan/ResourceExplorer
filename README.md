# `data` branch — pipeline state

This branch is **not source code**. It holds the persisted runtime state
that the weekly `resourcetracker` pipeline reads at the start of each
run and writes back at the end. Treat it as a force-pushable artefact
branch: only the GitHub Actions weekly job commits here.

## Contents

```
data/
├── warehouse/   # rds-backed tables -- nowcast history, ingest runs, raw + derived
└── cache/       # offline-fallback raw fetches keyed by source
```

Critical files:

- `data/warehouse/mart_nowcast_history.rds` — append-only per-run audit of every
  nowcast. Drives the "change since last run" section of the briefing.
- `data/warehouse/mart_ingest_runs.rds` — external-fetch audit log; the `--ci`
  guard in `run.R` reads this to detect all-stale runs.
- `data/cache/<source>/*.rds` — most-recent successful raw fetch per source.
  Used as the stale-cache fallback when PortWatch / DISR is unreachable.

## How the workflow uses this branch

1. On weekly cron, `actions/checkout@v4` pulls `main` for source code.
2. A second step runs `git fetch origin data` and restores
   `data/warehouse/` and `data/cache/` from `origin/data` into the
   workspace (those paths are gitignored on `main`, so this just
   materialises them — `git status` on `main` continues to ignore them).
3. `Rscript run.R --ci` runs, updating both directories in place.
4. A final step force-pushes the updated `data/` back to this branch.

## Do not branch off this

If you need to seed a new environment from a clean state, instead delete
this branch and let the next workflow run repopulate it from the
upstream PortWatch + DISR sources.
