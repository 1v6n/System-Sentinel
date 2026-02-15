# SystemSentinel

SystemSentinel is a C11 system monitoring service that exports host metrics on `/metrics` for Prometheus and Grafana. It also includes external uptime checks (SSH, HTTPS, DNS) with alerting through Alertmanager (Telegram).

## Table of Contents

- [SystemSentinel](#systemsentinel)
  - [Table of Contents](#table-of-contents)
  - [Quick Start](#quick-start)
  - [Architecture](#architecture)
  - [Repository Layout](#repository-layout)
  - [Configuration](#configuration)
  - [Access Points](#access-points)
  - [Verification](#verification)
  - [Grafana](#grafana)
  - [Pre-commit (clang-format + checks)](#pre-commit-clang-format--checks)
  - [Docker Space Maintenance](#docker-space-maintenance)
  - [CI with GitHub Actions](#ci-with-github-actions)
  - [Security Notes](#security-notes)
  - [Pre-commit Checklist Before Merging to `main`](#pre-commit-checklist-before-merging-to-main)

## Quick Start

Create runtime secrets file:

```bash
cp .env.example .env
```

Edit `.env` with your Telegram bot token and chat ID.
Set `SSH_TARGETS` to one or more SSH endpoints (comma-separated).
Use `Friendly Name=IP:PORT` to show aliases in Grafana/alerts. Example:
`Netbird Main=100.124.161.192:22,Backup SSH=10.0.0.15:22`.

Prerequisite: Docker Buildx plugin installed (`docker buildx version` must work).

One-command startup (recommended):

```bash
bash scripts/up.sh
```

Manual startup:

```bash
docker compose up -d --build
docker compose exec -T app sh -lc "printf '%s' 'cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_errors_total,tx_errors_total,dropped_packets_total' > /tmp/monitor_fifo"
```

## Architecture

- `app` (`SystemSentinel`): custom C exporter on port `8000`
- `prometheus`: scrapes app metrics and Blackbox probe results
- `blackbox-exporter`: external probes for:
  - `tcp_connect` to Netbird SSH endpoint `100.124.161.192:22`
  - HTTPS probe to `https://myadguardzi.duckdns.org/`
  - DNS A record resolution for `myadguardzi.duckdns.org` via resolver target `1.1.1.1:53`
- `alertmanager`: sends Telegram notifications
- `grafana`: visualization and dashboards

Container build strategy:

1. Build stage on Arch Linux (toolchain + compilation)
2. Runtime stage on `debian:bookworm-slim` (smaller, standard glibc runtime footprint)
3. Build artifacts are stripped (`strip --strip-unneeded`) to reduce final image size
4. App runs as non-root user (`systemsentinel`) in runtime image
5. App runtime is hardened in Compose (`read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`, `pids_limit`)

## Repository Layout

- `src/`, `include/`: C source and headers
- `lib/prometheus-client-c/`: git submodule to fork `https://github.com/1v6n/prometheus-client-c` (VERSION `0.1.3`)
- `docker-compose.yml`: full stack orchestration
- `prometheus/prometheus.yml.tmpl`: Prometheus config template
- `prometheus/alert.rules.yml.tmpl`: alert rules template
- `prometheus/entrypoint.sh`: runtime template renderer for Prometheus
- `blackbox/blackbox.yml`: probe modules
- `alertmanager/alertmanager.yml.tmpl`: Alertmanager template (runtime-rendered from `.env`)
- `.pre-commit-config.yaml`: local commit quality gates

## Configuration

Default metrics initialized by `scripts/up.sh` (can be overridden with `SYSTEM_SENTINEL_METRICS`):

```text
cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_errors_total,tx_errors_total,dropped_packets_total
```

Network interface behavior:

- `NETWORK_INTERFACE` empty: auto-detect first non-loopback interface
- `NETWORK_INTERFACE` set: force that interface explicitly

SSH probe behavior:

- `SSH_TARGETS` controls one or more blackbox SSH targets (`IP:PORT` or `Friendly Name=IP:PORT`, comma-separated)
- `SSH_TARGET` is still accepted as backward-compatible fallback
- The Grafana SSH availability panel displays this target from the `instance` label

## Access Points

- App metrics: `http://localhost:8000/metrics`
- Prometheus: `http://localhost:9090`
- Prometheus targets: `http://localhost:9090/targets`
- Alertmanager: `http://localhost:9093`
- Grafana: `http://localhost:3000`

## Verification

Basic health checks:

```bash
docker compose ps
curl -sS http://localhost:8000/metrics | head -n 20
curl -sS http://localhost:9090/-/ready
curl -sS http://localhost:9093/-/healthy
curl -sS http://localhost:9115/-/healthy
```

Prometheus probe checks:

```bash
curl -sS "http://localhost:9090/api/v1/query?query=probe_success{job=\"blackbox_duckdns_http\"}"
curl -sS "http://localhost:9090/api/v1/query?query=probe_success{job=\"blackbox_duckdns_dns\"}"
curl -sS "http://localhost:9090/api/v1/query?query=probe_success{job=\"blackbox_ssh\"}"
```

Expected probe value when healthy: `1`.

Submodule checks:

```bash
git submodule status
cat lib/prometheus-client-c/VERSION
```

## Grafana

Grafana provisioning is automatic:

1. Datasource `Prometheus` is preconfigured (`grafana/provisioning/datasources/datasource.yml`)
2. Dashboard provider loads dashboards from `grafana/dashboards/`
3. Custom dashboard `SystemSentinel Overview` is auto-imported at startup
4. SSH labels use `instance`; configure friendly aliases through `SSH_TARGETS` with `Friendly Name=IP:PORT`

Dashboard layout is operations-first and symmetric:

1. Top row (KPIs): `Endpoint Uptime % (24h)`, `SSH Uptime % (24h)`, `Error Budget Remaining (30d, 99.9% SLO)`
2. Diagnosis rows: state timeline/history + burn rate + SSH current status
3. Incident rows: `SSH Targets Down (Now)`, `Alerts`, and full-width `Firing Alert Details`
4. Bottom rows: host internals (CPU, memory, disk, network)

Panel-by-panel explanation:

1. `Endpoint Uptime % (24h)`: 24h availability for SSH aliases + DuckDNS HTTP/DNS.
2. `SSH Uptime % (24h)`: 24h availability for SSH alias targets only.
3. `Error Budget Remaining (30d, 99.9% SLO)`: remaining SLO budget per endpoint in the last 30 days.
4. `Availability State Timeline`: binary UP/DOWN timeline by endpoint.
5. `Availability Status History`: condensed status history view for flapping analysis.
6. `SLO Burn Rate (99.9% target)`: short/long window burn rate to detect fast budget consumption.
7. `SSH Current Status (Now)`: current UP/DOWN for SSH aliases.
8. `SSH Targets Down (Now)`: count of SSH targets currently down.
9. `Alerts`: number of firing alerts (shows `No alerts` when zero).
10. `Firing Alert Details`: active alert labels/annotations table.
11. `CPU Usage`: host CPU percentage.
12. `Memory Usage`: host RAM percentage.
13. `Disk Usage`: filesystem usage percentage.
14. `Available Memory`: available RAM in MB.
15. `Disk I/O Activity`: I/O activity rate.
16. `Network Error Rates`: RX/TX/dropped error rates.
17. `Network Throughput`: RX/TX bytes per second.
18. `Network Total Traffic`: cumulative RX/TX bytes.

Rendering and query notes:

- Uptime/budget gauges use fixed bounds (`min=0`, `max=1`) and threshold colors.
- Uptime gauges use 2 decimals and threshold ranges (`<95%` red, `95-99%` yellow, `>=99%` green).
- Heavy panels use `interval: 5m` and capped `maxDataPoints` to avoid oversampling warnings.
- SSH panels filter out legacy raw `IP:PORT` labels using `instance!~".*:[0-9]+$"`.

## Pre-commit (clang-format + checks)

Install tooling and hooks:

```bash
bash scripts/bootstrap-dev.sh
```

Run manually at any time:

```bash
bash scripts/run-hooks.sh all
```

Run only on staged files:

```bash
bash scripts/run-hooks.sh staged
```

Update hook versions (manual maintenance step, not per-commit):

```bash
bash scripts/update-hooks.sh
```

Recommended maintenance policy:

1. Use `bootstrap-dev.sh` once per machine
2. Use `run-hooks.sh staged` during daily development
3. Use `run-hooks.sh all` before opening a PR
4. Run `update-hooks.sh` periodically (for example monthly), review diff, then commit

## Docker Space Maintenance

Use the housekeeping script to keep Docker disk usage under control:

```bash
bash scripts/docker-housekeeping.sh report
bash scripts/docker-housekeeping.sh safe
```

Modes:

1. `report`: only shows Docker disk usage details
2. `safe`: prunes unused containers/images/build cache (keeps named volumes)
3. `aggressive`: prunes everything unused, including volumes (`--volumes`)

Use `aggressive` only when you know you can remove old data.

Configured hooks:

1. `clang-format` for `*.c` and `*.h`
2. YAML validation
3. Trailing whitespace / EOF fixes
4. Merge-conflict marker detection
5. Hardcoded Telegram secret detection

## CI with GitHub Actions

The workflow is defined in `.github/workflows/ci.yml` and runs on `push` and `pull_request`.

Checks performed:

1. Secret scan for hardcoded Telegram credentials
2. Pre-commit checks (`clang-format`, YAML, whitespace, merge markers)
3. `docker compose config` validation
4. Full stack build/start with `docker compose up -d --build`
5. Exporter initialization through FIFO
6. Smoke checks for:
   - `http://localhost:8000/metrics`
   - `http://localhost:9090/-/ready`
   - `http://localhost:9115/-/healthy`
   - `http://localhost:9093/-/healthy`
7. Logs artifact upload on failure

## Security Notes

- Keep Telegram credentials only in `.env` (ignored by git).
- If a token was ever committed or pasted in logs, rotate it immediately.

## Pre-commit Checklist Before Merging to `main`

```bash
bash scripts/run-hooks.sh all
docker compose config
docker compose up -d --build
curl -sS http://localhost:8000/metrics >/dev/null
```
