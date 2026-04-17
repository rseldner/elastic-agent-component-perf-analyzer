# Elastic Agent input performance analyzer

Turn Elastic Agent diagnostic NDJSON (`elastic-agent-*.ndjson`) into tab-separated metrics and an optional browser dashboard.

## Requirements

- Bash, [`jq`](https://stedolan.github.io/jq/), and `column` (common on macOS/Linux).

## Extract metrics

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

## Visualize

Open `input-analyzer.html` in a browser, then drop that `perf-analysis-*` folder (or the A–E `.tsv` files). Charts and health hints are built from the TSVs; missing tables are skipped.
