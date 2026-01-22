# Agent Metrics Dashboard

A stupid-simple dashboard for tracking agent autonomous runway over time.

## The KPI

**Average time between turn start and intervention** — how long can an agent work before a human has to step in? We want this number to go up over time.

Secondary metrics (later):
- Interrupt rate by task type
- Tool calls per autonomous stretch
- Self-recovery vs human-required failures

## Recommendation: Static HTML + Chart.js

Skip the dashboard frameworks. Homepage is for service bookmarks, Grafana is overkill.

Just build:
- Single HTML page with Chart.js
- Reads from a JSON file (`/var/lib/fort/metrics/agent-runway.json`)
- Served via existing fort static hosting
- Update the JSON however (cron, manual, future automation)

This is the fastest path to "a thing exists that shows a chart."

## Tasks

### 1. Create the dashboard page

Static HTML file with:
- Chart.js CDN import
- Line chart showing autonomous runway over time
- Maybe a bar chart for per-session breakdown
- Minimal styling, dark theme to match everything else

### 2. Create fake data file

`agent-runway.json` with structure like:
```json
{
  "sessions": [
    {"date": "2026-01-20", "avg_runway_seconds": 120, "interventions": 8},
    {"date": "2026-01-21", "avg_runway_seconds": 145, "interventions": 6},
    {"date": "2026-01-22", "avg_runway_seconds": 180, "interventions": 5}
  ]
}
```

### 3. Mount it somewhere

Either:
- `metrics.gisi.network` (new subdomain)
- `exocortex.gisi.network/metrics` (if we can add routes to flatnotes)
- `<host>.fort.gisi.network/metrics.html` (simplest, already have static serving)

### 4. (Future) Real data extraction

Parse conversation logs for turn timestamps. Not now — fake data first, prove the viz works.
