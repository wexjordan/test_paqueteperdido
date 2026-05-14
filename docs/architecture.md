# Architecture & Design Decisions

This document explains the internal design of **netmon-suite** — why it is built the way it is, and what trade-offs were made.

---

## Overview

```
  Datacenter A                      Datacenter B
  (Measurer)                        (Destination)
  ┌─────────────────────┐           ┌─────────────────────┐
  │  netmon-latency     │──TCP──▶   │                     │
  │  netmon-microcuts   │──UDP──▶   │   netmon-server     │
  │  netmon-connections │──TCP──▶   │   (echo TCP + UDP)  │
  └─────────────────────┘   ◀───────└─────────────────────┘
         │
         ▼
  /var/log/netmon/
         │
         ▼
  netmon-report  (analysis, run on demand)
```

All monitors run as systemd services under the unprivileged `netmon` system user. The server likewise runs as `netmon`. No root privileges are required at runtime.

---

## Why a Separate Server?

Alternatives considered:
- **ICMP ping (ping/fping)**: only measures ICMP, which many networks deprioritize or ratelimit. Does not reflect real application traffic.
- **iperf3**: measures throughput, not latency/microcuts. Complex setup.
- **Existing APM tools**: heavyweight, cloud-dependent, expensive. This suite is intentionally self-hosted and zero-dependency.

A custom TCP+UDP echo server on the same port was chosen because:
1. It accurately reflects the application layer (TCP socket behavior).
2. UDP gives sub-millisecond resolution that TCP retransmissions would hide.
3. A single binary/port pair is simple to firewall and audit.

---

## Monitor Design

### netmon-latency

- Keeps **one persistent TCP connection** to the server (reconnects on drop).
- Sends a 20-byte framed heartbeat every `LATENCY_INTERVAL` seconds (default: 100ms).
- Measures RTT with `time.perf_counter_ns()` (nanosecond precision).
- Aggregates into windows (`LATENCY_WINDOW` seconds): min, max, mean, p50, p95, p99, stddev, jitter, loss%.
- Writes aggregated rows to `latency/metrics-YYYY-MM-DD.csv` (append, one row per window).
- Writes anomaly events (high latency, connection drops) to `latency/events-YYYY-MM-DD.log`.

### netmon-microcuts

- Sends `MICROCUTS_RATE` UDP datagrams per second (default: 1000/s = 1ms resolution).
- Each datagram carries a monotonically increasing sequence number.
- Receives echoes and detects gaps in sequence numbers.
- `MICROCUTS_BURST_THRESHOLD` consecutive missing packets = a "microcut" event.
- Writes per-window stats to `microcuts/metrics-YYYY-MM-DD.csv`.
- Writes each microcut (timestamp, duration_ms, packet_count) to `microcuts/microcuts-YYYY-MM-DD.log`.

**Why UDP?** TCP retransmits lost packets transparently, so a 5-packet loss appears as a 5ms RTT spike rather than as loss. UDP exposes the loss directly.

**Why 1000/s?** It gives 1ms resolution with modest bandwidth (~10 KB/s per direction for 10-byte datagrams). Set `MICROCUTS_RATE=5000` for 0.2ms or `10000` for 0.1ms resolution if needed (more CPU/bandwidth).

### netmon-connections

- Maintains `CONNECTIONS_COUNT` (default: 4) **persistent TCP connections** simultaneously.
- Each connection sends a heartbeat every `CONNECTIONS_HEARTBEAT_INTERVAL` seconds.
- If no response in `CONNECTIONS_HEARTBEAT_TIMEOUT` seconds → **STALL** event.
- If the socket throws an exception → **DISCONNECT** event with the error type.
- Reconnects immediately and logs **RECONNECT** with downtime duration.
- Having multiple parallel connections lets you distinguish real outages (all 4 drop together) from per-path noise (1 of 4 drops due to ECMP asymmetry or a single firewall).

---

## netmon-server

A single Python process that:
1. Spawns a **TCP listener** thread: accepts connections, echoes all data, uses `TCP_NODELAY` to prevent Nagle buffering.
2. Runs a **UDP listener** loop in the main thread: echoes all received datagrams to sender.
3. Handles `SIGTERM`/`SIGINT` gracefully.

Both listeners share the same port number. The server enlarges UDP socket buffers (`SO_RCVBUF`/`SO_SNDBUF` to 4MB) to handle 1000+ datagrams/sec bursts without drops at the OS level.

---

## netmon-report

Reads the CSV and log files on disk — no running services needed. Design decisions:
- **Pure Python, no pandas/numpy**: keeps the zero-dependency promise. The files are small enough (a few MB/day) that stdlib `csv` is fine.
- **Correlation window**: events within `CORRELATION_WINDOW` seconds (default: 60s) of each other are grouped into a single "incident" and assigned a severity score.
- **Severity scoring**: `1 point` per latency alert, `2 points` per microcut, `5 points` per TCP disconnect, `3 points` per TCP stall. Incidents with score ≥ 8 are HIGH.

---

## Data Format

### latency/metrics-YYYY-MM-DD.csv

```
timestamp_utc,count,min_us,max_us,mean_us,p50_us,p95_us,p99_us,stddev_us,jitter_us,loss_pct
2026-05-13T03:40:00Z,100,10234,25678,12450,12200,18900,24500,1234,345,0.00
```

All latency values are in **microseconds** (integer). `loss_pct` is the fraction of pings with no response in the window.

### microcuts/metrics-YYYY-MM-DD.csv

```
timestamp_utc,sent,received,loss_pct,microcuts,max_cut_ms,total_lost_ms
2026-05-13T03:40:00Z,10000,9987,0.13,2,87.0,90.0
```

### microcuts/microcuts-YYYY-MM-DD.log

```
2026-05-13T03:42:15.234Z MICROCUT duration_ms=87.0 packets_lost=87
```

### connections/events-YYYY-MM-DD.log

```
2026-05-13T03:42:15.890Z DISCONNECT conn=0 error=ConnectionResetError uptime_prev=8742.3
2026-05-13T03:42:23.105Z RECONNECT  conn=0 downtime=7.21
2026-05-13T04:10:00.000Z STALL      conn=2 elapsed=12.3
```

---

## Security Model

- All daemons run as the `netmon` system user (no login shell, home under `/var/log/netmon`).
- Systemd units use `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=strict`, `ProtectHome=true`.
- The server only echoes data — it never executes, stores, or forwards anything.
- Configuration is in `/etc/netmon/netmon.conf` (mode 644). No secrets stored (no auth tokens, passwords, or keys).
- Recommended: restrict firewall rules to allow only the known peer IP on port 9999.

---

## Limitations & Known Gaps

- **IPv4 only**: IPv6 is not currently supported.
- **Single peer**: each installation monitors exactly one remote server. For N peers, run N client installations with different configs/ports.
- **No built-in alerting**: the suite is passive monitoring + historical analysis. For real-time paging, pipe `netmon-ctl report` into a cron job or hook into your existing alerting stack.
- **No TLS**: traffic between client and server is unencrypted. For sensitive networks, run over an existing VPN/tunnel.
- **Clock synchronization**: `netmon-report` uses local timestamps. If both servers have significantly drifted clocks (>1s), cross-server correlation will be inaccurate. Use NTP/chrony.
