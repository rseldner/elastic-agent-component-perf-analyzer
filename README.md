# Elastic Agent input performance analyzer

Analyze Elastic Agent diagnostic NDJSON (`elastic-agent-*.ndjson`) with either:

- a shell extractor + TSV workflow (`elastic-agent-perf.sh` + `input-analyzer.html`), or
- a standalone browser workflow (`input-analyzer-ndjson.html`) with no preprocessing step.

## Option 1: standalone offline browser viewer (no script required)

Open `input-analyzer-ndjson.html` in a browser and load a directory (or files) containing `elastic-agent-*.ndjson`.

- Parses NDJSON directly in-browser.
- Builds the same A-E metric tables used by the dashboard.
- Renders the same charts, health cards, and stall diagnostics.
- Works as an offline viewer: analysis is fully handled by your browser on local files.

No `jq`, no TSV generation, and no intermediary tooling required.

## Option 2: script extractor + TSV viewer

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

### Visualize TSV output

Open `input-analyzer.html` in a browser, then drop that `perf-analysis-*` folder (or A-E `.tsv` files). Missing tables are skipped gracefully.
