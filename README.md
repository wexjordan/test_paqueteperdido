# netmon-suite

**Continuous inter-datacenter network monitoring: latency, millisecond microcuts, and TCP connection drops.**

A suite of lightweight Linux daemons that run 24/7 between two servers in different datacenters to answer the question:  
> _"What exactly happened to the network at 3:42 AM last Tuesday?"_

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](https://kernel.org/)
[![Python: 3.7+](https://img.shields.io/badge/python-3.7%2B-green.svg)](https://www.python.org/)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)

---

## Why three monitors?

Because they measure fundamentally different things:

| Monitor | Layer | What it detects |
|---|---|---|
| **netmon-latency** | TCP RTT | High latency, jitter, gradual degradation |
| **netmon-microcuts** | UDP loss | Sub-millisecond disconnections TCP retransmissions hide |
| **netmon-connections** | TCP sockets | Real application-level connection drops (RST, stalls, timeouts) |
| **netmon-server** | — | Echo server on the remote side (TCP + UDP) |
| **netmon-report** | — | Correlated incident analysis across all three monitors |
| **netmon-ctl** | — | Unified control panel (start/stop/status/logs/report) |

Correlating all three with `netmon-report` tells you if an incident was **real** (multiple monitors saw it) or **noise** (only one did).

---

## Requirements

- **OS**: Linux with systemd (Debian 10+, Ubuntu 18.04+, RHEL/Rocky 8+, Amazon Linux 2+)
- **Python**: 3.7+ (no external packages needed — stdlib only)
- **Permissions**: root for installation (creates `netmon` system user, installs services)
- **Ports**: TCP **9999** and UDP **9999** open between both servers (configurable)
- **Disk**: ~5–10 MB/day of logs per host with default settings

---

## Quick Start

### 1. Copy the suite to both servers

```bash
scp -r netmon-suite/ user@server-A:/tmp/
scp -r netmon-suite/ user@server-B:/tmp/
```

### 2. Install by role

On **server B** (the remote/destination — runs `netmon-server`):
```bash
cd /tmp/netmon-suite
sudo bash install.sh server
```

On **server A** (the measurer — runs the monitors):
```bash
cd /tmp/netmon-suite
sudo bash install.sh client
```

To install both roles on the same host (useful for testing):
```bash
sudo bash install.sh both
```

### 3. Configure the peer IP

Edit `/etc/netmon/netmon.conf` on each server:
```ini
REMOTE_HOST=10.20.30.40      # IP of the OTHER datacenter
REMOTE_PORT=9999
```

### 4. Open the firewall (on server B)

```bash
# UFW (Debian/Ubuntu)
sudo ufw allow from <server-A-ip> to any port 9999 proto tcp
sudo ufw allow from <server-A-ip> to any port 9999 proto udp

# firewalld (RHEL/Rocky)
sudo firewall-cmd --permanent --add-port=9999/tcp
sudo firewall-cmd --permanent --add-port=9999/udp
sudo firewall-cmd --reload
```

> **Security tip**: Restrict by source IP as shown above. Do not open port 9999 to the world.

### 5. Test connectivity

```bash
sudo netmon-ctl test
```
Expected output:
```
TCP : OK
UDP : OK
Ping: OK (RTT avg: 12.345ms)
```

### 6. Start

```bash
sudo netmon-ctl start
sudo netmon-ctl status
```

---

## Daily Operation

All interaction goes through `netmon-ctl`:

```bash
sudo netmon-ctl start              # start all 3 monitors
sudo netmon-ctl stop               # stop all
sudo netmon-ctl restart            # restart all
sudo netmon-ctl status             # service status + today's event summary
sudo netmon-ctl logs               # last 50 lines of operational logs
sudo netmon-ctl logs 200           # last 200 lines
sudo netmon-ctl test               # test connectivity to peer
```

Sample `status` output:
```
═══════════════════════════════════════════════════════════════════
  netmon-latency             ● ACTIVE since 2026-05-13 14:32:18
  netmon-microcuts           ● ACTIVE since 2026-05-13 14:32:19
  netmon-connections         ● ACTIVE since 2026-05-13 14:32:19
═══════════════════════════════════════════════════════════════════

Current config:
  Remote host : 10.20.30.40
  Port        : 9999
  Logs        : /var/log/netmon/

Events today (2026-05-14 UTC):
  Microcuts          : 12
  TCP disconnections : 0
  TCP stalls         : 0
  Latency alerts     : 3
```

---

## Incident Investigation

### Step 1: Executive summary

```bash
sudo netmon-ctl report summary --day 2026-05-13
```
Shows: global latency metrics (p50, p99, worst max), total microcuts, TCP drops/stalls/reconnects, downtime, and the **top 3 correlated incidents**.

### Step 2: Hourly view

```bash
sudo netmon-ctl report hourly --day 2026-05-13
```
```
Hour UTC              p99 med        max   µcuts   cut max  discs  stalls    down
─────────────────────────────────────────────────────────────────────────────────
2026-05-13 02:00       12.50ms     25.10ms      0     0.0ms      0       0     0s
2026-05-13 03:00       45.20ms    250.30ms     17    87.0ms      1       2  15.2s ●
2026-05-13 04:00       12.30ms     22.10ms      0     0.0ms      0       0     0s
```
The `●` marks problem hours. Here you can clearly see something happened at **03:00 UTC**.

### Step 3: Timeline of a specific hour

```bash
sudo netmon-ctl report timeline --day 2026-05-13 --hour 3
```
```
TIMELINE — 2026-05-13 hour 03:00 UTC
─────────────────────────────────────────────────────────────────
  03:42:15.234  [      MCUT]  87.0ms lost (87 packets)
  03:42:15.890  [DISCONNECT]  conn=0 error=ConnectionResetError uptime_prev=8742.3s
  03:42:15.891  [DISCONNECT]  conn=1 error=ConnectionResetError uptime_prev=8742.3s
  03:42:23.105  [ RECONNECT]  conn=0 downtime=7.21s
```
**Incident confirmed**: at 03:42:15 there was an 87ms microcut and simultaneously all 4 TCP connections dropped with `ConnectionResetError`. This is a real network event, not noise.

### Step 4: Correlated incidents

```bash
sudo netmon-ctl report incidents --day 2026-05-13 --verbose
```

### Step 5: Historical tops

```bash
# 10 longest microcuts in the last 7 days
sudo netmon-ctl report top --by microcuts --limit 10 --start 2026-05-06 --end 2026-05-13

# 10 longest TCP downtimes
sudo netmon-ctl report top --by downtime --limit 10 --start 2026-05-01

# 10 most severe incidents this month
sudo netmon-ctl report top --by severity --limit 10 --start 2026-05-01 --end 2026-05-31
```

---

## Configuration Reference

Edit `/etc/netmon/netmon.conf` (see `netmon.conf.example` for all options):

| Variable | Default | Description |
|---|---|---|
| `REMOTE_HOST` | — | **Required.** IP of the peer in the other DC |
| `REMOTE_PORT` | `9999` | Port (TCP and UDP, same number) |
| `LATENCY_INTERVAL` | `0.1` | Seconds between TCP pings (0.1 = 10/s) |
| `LATENCY_WINDOW` | `10` | Aggregation window in seconds |
| `MICROCUTS_RATE` | `1000` | UDP pings per second (1000 = 1ms resolution) |
| `MICROCUTS_BURST_THRESHOLD` | `2` | Consecutive lost packets to count as a microcut |
| `CONNECTIONS_COUNT` | `4` | Parallel persistent TCP connections |
| `CONNECTIONS_HEARTBEAT_INTERVAL` | `5` | Seconds between heartbeats per connection |
| `CONNECTIONS_HEARTBEAT_TIMEOUT` | `10` | Seconds before declaring a connection "stalled" |

After editing, reload:
```bash
sudo netmon-ctl restart
```

---

## Interpreting Results

### Latency metrics

| Metric | Meaning | When to worry |
|---|---|---|
| **p50 (median)** | Typical RTT | If rises >2× baseline → degradation |
| **p99** | Worst 1% | If >5× median → frequent microbursts |
| **max** | Worst in window | If >100× median → severe one-off spike |
| **jitter** | Consecutive sample variation | High = bad for VoIP, gaming, trading |

### UDP microcut durations

| Duration | Likely cause |
|---|---|
| 2–10ms | Switch/router buffer queue (common, usually ignorable) |
| 10–50ms | Routing reconfig, microcongestion, GC on a hop |
| 50–500ms | Failover, link flap, real problem |
| >500ms | Link down or major reroute |

> **Note**: many 2–3ms microcuts on WAN links are normal. Focus on **long** cuts and cuts **correlated with TCP disconnections**.

### TCP connection errors

| Error | Meaning |
|---|---|
| `ConnectionResetError` / `ECONNRESET` | Peer or stateful firewall sent RST (common: idle session timeout) |
| `TimeoutError` (STALL) | Peer stopped responding without closing — network "freeze" |
| `BrokenPipeError` / `EPIPE` | Tried to write to a dead socket |
| `ConnectionRefusedError` | Remote server is down |
| `EHOSTUNREACH` / `ENETUNREACH` | Broken routing |

> **Golden rule**: if **all 4 connections drop at the same second** → real network event. If **1 of 4** → likely noise (ECMP path issue, one firewall, etc.).

---

## Log Files

All logs live under `/var/log/netmon/`:

```
/var/log/netmon/
├── latency/
│   ├── metrics-YYYY-MM-DD.csv       # TCP aggregated metrics per window
│   ├── events-YYYY-MM-DD.log        # Latency anomalies
│   └── latency.log                  # Operational log
├── microcuts/
│   ├── metrics-YYYY-MM-DD.csv       # UDP metrics per window
│   ├── microcuts-YYYY-MM-DD.log     # Each microcut with exact duration
│   ├── events-YYYY-MM-DD.log        # Notable events
│   └── microcuts.log                # Operational log
└── connections/
    ├── events-YYYY-MM-DD.log        # Disconnections, stalls, reconnects
    └── connections.log              # Operational log
```

---

## Project Structure

```
netmon-suite/
├── README.md                   # This file (English)
├── LEEME.md                    # Spanish documentation
├── LICENSE                     # MIT License
├── CONTRIBUTING.md             # Contribution guidelines
├── install.sh                  # Installer (server / client / both)
├── netmon.conf.example         # Annotated configuration file
├── bin/
│   ├── netmon-server           # TCP+UDP echo server (Python)
│   ├── netmon-latency          # TCP latency monitor (Python)
│   ├── netmon-microcuts        # UDP microcut detector (Python)
│   ├── netmon-connections      # TCP connection health monitor (Python)
│   ├── netmon-report           # Correlated incident analyzer (Python)
│   └── netmon-ctl              # Unified control panel (Bash)
├── systemd/
│   ├── netmon-server.service
│   ├── netmon-latency.service
│   ├── netmon-microcuts.service
│   └── netmon-connections.service
└── docs/
    └── architecture.md         # Detailed architecture and design decisions
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `netmon-ctl test` TCP fails | Is `netmon-server` running on server B? Is port 9999 TCP open? |
| `netmon-ctl test` UDP fails | Is port 9999 UDP open in the firewall? |
| Service fails to start | `journalctl -u netmon-latency -n 50` — check for Python errors or missing config |
| No logs appearing | Check `/etc/netmon/netmon.conf` — `REMOTE_HOST` must be set |
| `Permission denied` errors | The `netmon` system user must own `/var/log/netmon/` — re-run installer |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

[MIT](LICENSE) © 2026
