# Installation Guide

This guide covers installation and environment setup details.
For architecture, dashboards, and day-to-day operations, use `README.md`.

## Scope

Use this document when you need to:
- Set up a new machine
- Bootstrap dependencies
- Initialize submodules correctly
- Validate first deployment end-to-end

## 1. Prerequisites

Required on host:
- Docker Engine
- Docker Compose V2 (`docker compose`)
- Docker Buildx plugin
- Git

Quick verification:

```bash
docker info
docker compose version
docker buildx version
git --version
```

## 2. Repository Setup

Clone and initialize submodules:

```bash
git clone <your-repo-url>
cd UNC-OS-Practical1
git submodule update --init --recursive
```

Validate Prometheus client submodule source and version:

```bash
cat .gitmodules
cat lib/prometheus-client-c/VERSION
```

Expected:
- Submodule URL points to your fork (`https://github.com/1v6n/prometheus-client-c`)
- `VERSION` matches the pinned release you use (currently `0.1.3`)

## 3. Environment Configuration

Create runtime env file:

```bash
cp .env.example .env
```

Set required variables in `.env`:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

Optional:
- `NETWORK_INTERFACE`
  - Empty: app auto-detects the first non-loopback interface
  - Set value (for example `eth0`): force a specific interface

## 4. Deployment (Recommended)

Use the project bootstrap script:

```bash
bash scripts/up.sh
```

What it does:
1. Builds and starts the full stack
2. Waits for FIFO availability in the app container
3. Initializes the exporter metric set automatically

## 5. Deployment (Manual)

If you need full control:

```bash
docker compose up -d --build
docker compose exec -T app sh -lc "printf '%s' 'cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_errors_total,tx_errors_total,dropped_packets_total' > /tmp/monitor_fifo"
```

## 6. First Health Validation

Container status:

```bash
docker compose ps
```

Service health endpoints:

```bash
curl -sS http://localhost:8000/metrics | head -n 20
curl -sS http://localhost:9090/-/ready
curl -sS http://localhost:9093/-/healthy
curl -sS http://localhost:9115/-/healthy
```

UI endpoints:
- Prometheus: `http://localhost:9090`
- Alertmanager: `http://localhost:9093`
- Grafana: `http://localhost:3000`

## 7. Platform-Specific Notes

### Arch / CachyOS

Install Buildx if missing:

```bash
sudo pacman -S docker-buildx
```

If Docker daemon is not running:

```bash
sudo systemctl enable --now docker.service
```

## 8. Recovery Scenarios

### Rebuild app image from scratch

```bash
docker compose build --no-cache app
docker compose up -d --force-recreate app
```

### Recreate full stack

```bash
docker compose down
docker compose up -d --build
```

### Reinitialize submodule after branch changes

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

## 9. Local Build Without Docker (Optional)

This path is only for native C development/debugging.

Example dependencies on Arch:

```bash
sudo pacman -S --needed base-devel cmake libmicrohttpd pkgconf
```

Build Prometheus C libs:

```bash
cmake -S lib/prometheus-client-c/prom -B /tmp/build-prom -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build /tmp/build-prom --config Release
sudo cmake --install /tmp/build-prom

cmake -S lib/prometheus-client-c/promhttp -B /tmp/build-promhttp -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build /tmp/build-promhttp --config Release
sudo cmake --install /tmp/build-promhttp
```

Build app:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/SystemSentinel
```

## 10. Post-Install Maintenance

For Docker disk usage cleanup:

```bash
bash scripts/docker-housekeeping.sh report
bash scripts/docker-housekeeping.sh safe
```

Use `aggressive` mode only when you explicitly accept volume cleanup.
