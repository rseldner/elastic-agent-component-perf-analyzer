# Elastic Agent component performance analyzer

**Live Working DEMO**: https://rseldner.github.io/elastic-agent-component-perf-analyzer/input-analyzer.html

Explore Elastic Agent component performance from diagnostic exports in one browser dashboard: `input-analyzer.html`.

**Versioning:** the release is recorded in the repository root `VERSION` file. The in-browser app shows that build next to the header subtitle (`APP_VERSION` in `input-analyzer.html`; keep the two in sync). The `elastic-agent-perf.sh` extractor reads `VERSION` automatically, supports `--version`, and writes `EXTRACTOR_VERSION.txt` into each `perf-analysis-*` output folder.

It supports both:

- raw NDJSON log files (`elastic-agent-*.ndjson`), and
- extracted A-E TSV outputs from `elastic-agent-perf.sh`.

The page auto-detects whether you loaded NDJSON or TSV and renders the same charts, health cards, and stall diagnostics.

## Dashboard sections (`input-analyzer.html`)

The layout is top-to-bottom: context and verdict-style signals first, then the detailed time-series. Rough order:

- **Header** — Component selector (after load), copy buttons for the active component ID, light/dark theme, repo link, and a small **analyzer build** version next to the title.
- **Top metadata** — For the selected component: **Component ID** (and copy), **time window** and **interval count**, and the **beat / agent version** string from metrics (identity, not a performance roll-up). Optional **Dataset keys** expander: quick status per `monitoring.dataset` key for that component (same health rules as Table D below), with a link to scroll to the table.
- **Stall banner** — When the export matches a stall signature, a colored banner explains the likely class (e.g. ingestion buffer vs pipeline vs output deadlock vs idle source) and, when applicable, how persistent it looks across intervals.
- **Health grid** — Short **pass / warn / fail** tiles for a fast read (e.g. throughput, queue, pipeline, output, memory, dataset key health when Table D is present).
- **Alerts** — **Issues** (errors/warnings) and **Health & context** (informational) in collapsible groups; use these after the health grid for narrative detail and copyable IDs.
- **Event flow** — Rolled-up **ingest / queue / output / ack** picture with **Latest**, **Worst**, or **Mean** roll-up, optional per-interval alignment, backlog variability, and a **By time in window** strip and spark when enough data exists.
- **Event flow by layer** — **FB_ACTIVE** (when present), **PIPE_ACTIVE**, and **OUT_ACTIVE** over time (in-flight work per layer); complements the node diagram above.
- **Summary** — Stat cards for **output delivery and latency**, **pipeline & queue**, and **beat process** (e.g. acks/fails, queue peak, OUT_ACTIVE, write latency peaks, RSS, heap swing, goroutines). Version is *not* repeated here; it is in the top metadata.
- **Ingestion codec & processing (dataset keys)** — Shown when the diagnostic includes **D** / `monitoring.dataset` **processing_time** data: a **per–dataset key** table and bar chart (codec/ingress processing time from lifetime histograms), distinct from the ingestion *buffer* (**FB_ACTIVE**) in Event flow.
- **Pipeline & queue** — Queue fill and pipeline activity time series (Table **B**).
- **Output delivery** — Event counts, **write latency** reservoirs, I/O, error / retry percentages, and transport read/write error counters (Table **A** and **E**).
- **Beat resources** — Memory, CPU, and optional **harvester** and **file descriptor** charts (Table **C**).

## Option 1: direct NDJSON analysis (no script required)

Open `input-analyzer.html` in a browser and load files/folders containing `elastic-agent-*.ndjson`.

- NDJSON is parsed directly in-browser.
- A-E metric tables are built in-browser.
- Analysis remains local/offline in your browser.

No `jq`, no TSV generation, and no intermediary tooling required.

## Option 2: extractor workflow (`elastic-agent-perf.sh` + TSV)

### Requirements

- Bash, [`jq`](https://stedolan.github.io/jq/), and `column` (common on macOS/Linux).

### Extract metrics

From a directory that contains `elastic-agent-*.ndjson`:

```bash
chmod +x elastic-agent-perf.sh
./elastic-agent-perf.sh [options] /path/to/logs
```

Useful options: `--all` (every component), `--component <id>`, `--component-regex <pattern>`, `--list` (components only). Run `./elastic-agent-perf.sh --help` for details.

Output goes to `perf-analysis-YYYYMMDD-HHMMSS/` under the log directory, with five space-aligned TSV files:

```
A-output-health.tsv
B-pipeline-queue.tsv
C-beat-resources.tsv
D-input-processing.tsv
E-health-ratios.tsv
```

- **D** (`D-input-processing.tsv`) — per-dataset-key `processing_time` from `monitoring.dataset` in the logs (not the same as the ingestion buffer / FB_ACTIVE in the UI). Omitted if the beat never reports those histograms.

### Visualize TSV output

Open `input-analyzer.html` in a browser, then drop that `perf-analysis-*` folder (or A-E `.tsv` files). Missing tables are skipped gracefully.

## Sharing and sanitization note

Using `elastic-agent-perf.sh` can help for sanitization scenarios: sharing only the generated TSV files is usually lower risk than sharing raw NDJSON logs.

Those TSV outputs are metric-focused and typically include component IDs, timestamps, and aggregate counters/latencies rather than raw event payloads, host IPs, or secrets. Still, treat them as operational telemetry and review before sharing, since environment-specific identifiers and timing data can still be sensitive in some contexts.


### Screenshot

<img width="3408" height="7403" alt="image" src="https://github.com/user-attachments/assets/dd0690da-7153-4786-a802-abdb626c2e38" />

 
