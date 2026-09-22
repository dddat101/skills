# Core Principles & Architecture

This document details the foundation of the Linux Network Test Lab Framework, covering core philosophies, supported topology models, and standard directory architecture.

---

## 1. The 11 Core Philosophies

1. **Traffic Isolation via Network Namespaces (`netns`)**:
   - Entities (Clients, Mock Servers, Attackers, Monitors) are segregated into dedicated Linux namespaces.
   - Test traffic must traverse the physical or virtual data plane of the DUT (Device Under Test) without internal host bypassing.

2. **Host Safety & Smart Unmanage**:
   - **Never** flush global host firewall tables (`iptables`/`nftables`).
   - **Never** touch or disrupt the host's default route. Loopback (`lo`) and interfaces carrying default routes are strictly rejected.
   - **Auto-handle NetworkManager**: USB Ethernet NICs often receive unwanted DHCP or link-local IPs from NetworkManager. The framework unmanages them (`nmcli device set <iface> managed no`) and flushes stale IPs (`ip addr flush dev <iface>`) automatically.

3. **Idempotency & Auto-Rollback**:
   - `setup.sh` and `cleanup.sh` can run repeatedly without accumulating errors or orphaned resources.
   - `setup.sh` utilizes an auto-rollback trap (`trap ERR`) to cleanly tear down intermediate bridges and namespaces if any setup step fails.

4. **Bash Strict Mode & SIGPIPE Prevention**:
   - Shell scripts enforce `set -Eeuo pipefail` and `IFS=$'\n\t'`.
   - Pipeline commands that terminate early (e.g. `tshark ... | head -n1`) cause error 141 (`SIGPIPE`) under `pipefail`. All pipelines must be protected: `(tshark ... 2>/dev/null || true) | head -n1`.

5. **Config-as-Data & Strict Quoting**:
   - All environment variables, interface names, IP ranges, timeouts, and BPF filters reside in `config.env`.
   - String values containing spaces, BPF filters, or commas must be double-quoted (`CAPTURE_FILTER="igmp or udp"`).

6. **Flexible Topology Modes (Single-PC, Two-PC, Virtual Mode)**:
   - **Mode 1: Physical Single-PC (Dual-NIC)** (`LAB_ROLE="single"`): Single machine with 2 physical NICs (`WAN_IF` and `LAN_IF`) cabled directly to DUT.
   - **Mode 2: Physical Distributed Two-PC** (`LAB_ROLE="wan"` / `"lan"`): Two independent PCs coordinated via SSH (`PEER_SSH_HOST`).
   - **Mode 3: Virtual / No-DUT Simulation** (`--virtual` / `--no-dut`): 100% software emulation via `veth` pairs and `ns-dut` namespace for CI/CD and offline development.

7. **Verification by Evidence**:
   - Automated tests rely on packet captures (`.pcap`/`.pcapng`) evaluated via `tshark` in `verify_*.sh`.
   - Quantitative criteria (Join latency $\le 20\text{ms}$, backoff duration $\sim 2.0\text{s}$, traffic drops) determine definitive `[PASS]` / `[FAIL]` verdicts.

8. **Non-Root Graceful Degradation & Safe Permissions (`0777`)**:
   - Inspection commands (`-h`/`--help`, `diagnose.sh`, `show_state.sh`, `verify_*.sh`) run smoothly without `sudo`.
   - Runtime folders (`captures/`, `logs/`, `state/`) are created with mode `0777` (`chmod -R a+rw`) to eliminate permission collisions between `root` and normal users.

9. **Deterministic Synchronization vs. Arbitrary Sleep**:
   - Eliminate hardcoded delays (`sleep 1`, `sleep 2`).
   - Use deterministic socket polling: `wait_for_port <port> <host> <timeout>` and `wait_for_http <url> <expected_code> <timeout>`.

10. **Reliable Process Management & Stale PID Detection**:
    - Distinguish live processes from abandoned `.pid` files after system crashes (`kill -0` and `/proc/<pid>`).
    - Escalate process termination in 3 tiers: `SIGINT` (flush buffers) $\rightarrow$ `SIGTERM` (graceful shutdown) $\rightarrow$ `SIGKILL` (force cleanup).
    - Cleanup orphan background jobs using `stop_process_by_pattern`.

11. **CLI Standards & User-Friendly Help**:
    - 100% of scripts support `-h` and `--help` with exit code `0`, requiring no `sudo`, no pre-installed dependencies, and no existing runtime state.
    - Usage messages follow the standard 6-section structure: `Description`, `Usage`, `Options / Arguments`, `Subcommands`, `Examples`, and `Suggested Next Steps`.

---

## 2. Supported Topology Modes

### Mode 1: Physical Single-PC Dual-NIC
```text
+-------------------------------------------------------------+
| HOST LINUX PC                                               |
|  +---------------------+           +---------------------+  |
|  | netns: ns-wan       |           | netns: ns-lan       |  |
|  | IP: 10.10.0.10/24   |           | IP: 192.168.1.100/24|  |
|  | dev: eth-wan        |           | dev: eth-lan        |  |
|  +----------+----------+           +----------+----------+  |
|             | (veth)                          | (veth)      |
|  +----------+----------+           +----------+----------+  |
|  | Bridge: br-test-wan |           | Bridge: br-test-lan |  |
|  | Member: WAN_IF      |           | Member: LAN_IF      |  |
|  +----------+----------+           +----------+----------+  |
+-------------|---------------------------------|-------------+
              | (Physical USB NIC)              | (Physical USB NIC)
              v                                 v
        [ DUT WAN Port ]                 [ DUT LAN Port ]
        +-----------------------------------------------+
        | DUT (Device Under Test) Hardware Router       |
        +-----------------------------------------------+
```

### Mode 2: Virtual / No-DUT Simulation Mode
```text
+-------------------------------------------------------------+
| LINUX HOST (No Physical Hardware Required)                  |
|  +---------------+    +-----------------+    +------------+  |
|  | netns: ns-wan |    | netns: ns-dut   |    | netns: ns- |  |
|  | 10.10.0.10/24 |    | Bridge: br-dut  |    |     lan    |  |
|  | (Mock WAN Srv)|    | 10.10.0.1/24    |    | 192.168.1. |  |
|  |               |    | 192.168.1.1/24  |    |    100/24  |  |
|  +-------+-------+    +---+---------+---+    +-----+------+  |
|          | (veth)         | (veth)  | (veth)       | (veth)  |
|  +-------+----------------+--+   +--+--------------+------+  |
|  | Bridge: br-test-wan       |   | Bridge: br-test-lan    |  |
|  +---------------------------+   +------------------------+  |
+-------------------------------------------------------------+
```

---

## 3. Standard Directory Architecture

```text
<lab_project_name>/
├── .gitignore                    # Local configs, logs, pids, pcaps, .venv
├── config.env.example            # Annotated template with strict string quoting
├── README.md                     # Architecture, Mermaid diagrams, execution instructions
├── docs/
│   ├── SHELL_STYLE.md            # Bash strict mode guidelines
│   ├── TEST_PLAN.md              # Test matrix, preconditions, PASS/FAIL criteria
│   └── TROUBLESHOOTING.md        # Hardware & Linux diagnostic runbook
├── captures/                     # Runtime packet captures (.pcap / .pcapng)
│   └── .gitkeep
├── logs/                         # Daemon stdout/stderr, audit logs
│   └── .gitkeep
├── state/                        # Runtime state: .pid files, topology_state.env, last_capture.env
│   └── .gitkeep
├── tools/                        # (Optional) Scapy or Python test agents / socket tools
│   └── <tool_name>.py
└── scripts/
    ├── lib/
    │   ├── common.sh             # Reusable helper library
    │   └── udhcpc.script         # Safe IP/route configuration inside netns
    ├── setup.sh                  # Topology initialization with auto-rollback trap
    ├── cleanup.sh                # Idempotent cleanup with restore vs down mode
    ├── capture.sh                # Packet capture manager (start | stop | status | clean)
    ├── show_state.sh             # Runtime status inspector (stale PID detection)
    ├── diagnose.sh               # Non-destructive pre-flight environment checks
    ├── run_smoke.sh              # One-touch diagnostic and state runner
    ├── dut_collector.sh          # Remote telemetry snapshot via SSH
    ├── start_servers.sh          # Start mock servers with wait_for_port
    ├── stop_servers.sh           # Stop mock servers cleanly
    ├── scenario.sh               # Modular multi-phase automated test runner
    ├── client_dhcp.sh            # Netns DHCP client manager (Option 12/60)
    └── verify_compliance.sh      # Dual-layer verification & ASCII timeline engine
```
