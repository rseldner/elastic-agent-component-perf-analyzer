# Elastic Agent component performance analyzer

**Live Working DEMO**: https://rseldner.github.io/elastic-agent-component-perf-analyzer/input-analyzer.html

Explore Elastic Agent component performance from diagnostic exports in one browser dashboard: `input-analyzer.html`.

It supports both:

- raw NDJSON log files (`elastic-agent-*.ndjson`), and
- extracted A-E TSV outputs from `elastic-agent-perf.sh`.

The page auto-detects whether you loaded NDJSON or TSV and renders the same charts, health cards, and stall diagnostics.

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

<img width="693" height="2219" alt="screenshot" src="https://github.com/user-attachments/assets/b0cb1bc9-86bc-4ebf-abaa-8de7d9a1e05d" />

 
