---
name: network-test-lab
description: >-
  Comprehensive guide, standards, and automation tooling for designing, scaffolding, running, and verifying Linux Network Test Labs (using network namespaces, veth pairs, Linux bridges, automated packet capture, and PCAP analysis). Activate this skill when the user asks to create or scaffold a network test lab, write or modify network lab scripts (setup.sh, cleanup.sh, capture.sh, scenario.sh, verify_*.sh, diagnose.sh, show_state.sh), manage network namespaces, veth pairs, Linux bridges, DHCP client/server isolation, or debug network test issues (host safety, NetworkManager conflicts, SIGPIPE 141, tshark privilege drops, stale PIDs, non-root CLI standards).
---

# Linux Network Test Lab Framework

A production framework for building automated, reproducible, evidence-based Network Test Labs on Linux. Uses Linux Network Namespaces (`netns`), `veth` pairs, Linux Bridges, background packet capture (`tcpdump`), and automated packet analysis (`tshark`).

---

## 1. The 11 Golden Principles

| # | Principle | Enforcement |
| :- | :--- | :--- |
| 1 | **Traffic Isolation** | Segregate clients, servers, and monitors into dedicated `netns`. |
| 2 | **Host Safety & Smart Unmanage** | Never touch host default route or firewall. Auto-unmanage NetworkManager on test NICs (`nmcli device set <iface> managed no`). |
| 3 | **Idempotency & Auto-Rollback** | All scripts run repeatedly without error. `setup.sh` arms `trap 'rollback_setup $? ${LINENO}' ERR`. |
| 4 | **Bash Strict Mode & SIGPIPE** | `set -Eeuo pipefail`, `IFS=$'\n\t'`. Wrap pipelines: `(cmd 2>/dev/null \|\| true) \| head -n1`. |
| 5 | **Config-as-Data & Quoting** | All parameters in `config.env`. Double-quote all strings, BPF filters, and option flags. |
| 6 | **3-Mode Topology Flexibility** | Support **Single-PC** (`--single`), **Distributed 2-PC** (`--wan`/`--lan`), and **Virtual Simulation** (`--virtual`). |
| 7 | **Verification by Evidence** | Results verified via `.pcap` inspection with `tshark`. Quantitative criteria yield `[PASS]`/`[FAIL]`. |
| 8 | **Non-Root Graceful Degradation** | `-h`/`--help`, `diagnose.sh`, `show_state.sh`, `verify_*.sh` run without `sudo`. Runtime dirs are `0777`. |
| 9 | **Deterministic Synchronization** | No arbitrary `sleep`. Use `wait_for_port <port> [host] [timeout] [ns]` and `wait_for_http`. |
| 10 | **Reliable Process Lifecycle** | Supervise via `.pid` files, detect stale PIDs (`kill -0`), escalate stop: `SIGINT` $\rightarrow$ `SIGTERM` $\rightarrow$ `SIGKILL`. |
| 11 | **Canonical CLI Standards** | 100% of scripts support `-h`/`--help` with exit code `0` and 6-section `usage()` structure. |

For a complete breakdown of each principle, see [references/principles_and_architecture.md](references/principles_and_architecture.md).

---

## 2. Standard Directory Layout

```text
<lab_project_name>/
├── config.env.example            # Configuration template (strict quoting)
├── .gitignore                    # Ignores config.env, state/*, logs/*, captures/*, .venv
├── README.md                     # Overview, Mermaid Sequence diagram, quickstart commands
├── docs/
│   ├── SHELL_STYLE.md            # Bash strict mode guidelines
│   ├── TEST_PLAN.md              # Test matrix & PASS/FAIL criteria
│   └── TROUBLESHOOTING.md        # Hardware & Linux diagnostic runbook
├── captures/                     # Storage for *.pcap / *.pcapng captures (mode 0777)
├── logs/                         # Storage for daemon and audit logs (mode 0777)
├── state/                        # Runtime PID files, topology_state.env, last_capture.env
├── tools/                        # Python Scapy, socket clients, or attack tools
└── scripts/
    ├── lib/
    │   ├── common.sh             # Core helper library
    │   └── udhcpc.script         # Namespace-safe DHCP event script
    ├── setup.sh                  # Topology builder with auto-rollback trap
    ├── cleanup.sh                # Idempotent teardown & NIC restoration
    ├── capture.sh                # Background packet capture manager (tcpdump-first)
    ├── show_state.sh             # Runtime status inspector & stale PID detector
    ├── diagnose.sh               # Non-destructive pre-flight diagnostic runner
    ├── scenario.sh               # Modular multi-phase test scenario runner
    └── verify_compliance.sh      # Dual-layer verification engine with ASCII timeline
```

---

## 3. Core Workflows

### Workflow A: Scaffolding a New Test Lab
To generate a complete, standardized lab skeleton in seconds:

```bash
# Run the scaffolding tool included in this skill:
./scripts/scaffold_lab.sh <target_directory> [--virtual | --single]

# Example:
./scripts/scaffold_lab.sh /home/dddat/workspace/my_dhcp_lab --virtual
```
This generates all scripts, templates, documentation, and directory permissions automatically.

### Workflow B: Topology Setup & Teardown
```bash
# Pre-flight environment check (runs non-root)
./scripts/diagnose.sh

# Deploy Virtual simulation (zero hardware needed)
sudo ./scripts/setup.sh --virtual

# Or deploy physical Single-PC Dual-NIC topology
sudo ./scripts/setup.sh --single

# Inspect running state
./scripts/show_state.sh

# Teardown and restore physical interfaces (default: restores NM and DHCP)
sudo ./scripts/cleanup.sh

# Teardown with interfaces left isolated in DOWN state
sudo ./scripts/cleanup.sh -d

# Non-destructive cleanup of artifacts only (runs non-root)
./scripts/cleanup.sh logs
./scripts/cleanup.sh captures
./scripts/cleanup.sh data
```
Detailed guide: [references/topology_and_lifecycle.md](references/topology_and_lifecycle.md).

### Workflow C: Executing Test Scenarios & Traffic
```bash
# Run complete test suite (starts capture -> executes phases -> stops capture -> verifies)
sudo ./scripts/scenario.sh all

# Run specific phase
sudo ./scripts/scenario.sh discovery
sudo ./scripts/scenario.sh traffic
sudo ./scripts/scenario.sh security
```

### Workflow D: PCAP Inspection & Verification
```bash
# Verify the latest capture file
./scripts/verify_compliance.sh

# Verify a specific capture file
./scripts/verify_compliance.sh captures/my_capture.pcap
```
Detailed guide: [references/pcap_verification_and_evidence.md](references/pcap_verification_and_evidence.md).

---

## 4. Critical Rules & Anti-Patterns (Must Avoid)

1. **The `dumpcap` Privilege Drop Trap**:
   - Never use `tshark` directly for background packet capture under `sudo`. `dumpcap` drops privileges to an unprivileged user/group and fails with `Permission denied`.
   - **Always** capture with `tcpdump -ni <iface> -s 0 -U -w <file.pcap>`, and use `tshark` exclusively for post-capture verification.
2. **The 4 CLI Help Traps**:
   - Never invoke `require_root`, `require_cmd`, or state assertions before checking `$@` for `-h`/`--help`.
   - Always exit `0` on help requests.
   - Follow the Canonical CLI Pattern: [references/cli_standards_and_pitfalls.md](references/cli_standards_and_pitfalls.md).
3. **The DHCP `/etc/resolv.conf` Overwrite**:
   - Never run `udhcpc -s /etc/udhcpc/default.script` inside a namespace (it corrupts host DNS).
   - Never run `udhcpc -s /bin/true` (it fails to assign the acquired IP).
   - Always use `scripts/lib/udhcpc.script`: [references/dhcp_and_namespace_isolation.md](references/dhcp_and_namespace_isolation.md).
4. **Never Quote IP Addresses in `tshark -Y`**:
   - Wireshark 4.2+ fails on `ip.src == "10.10.0.1"`. Always write `ip.src == 10.10.0.1`.
5. **Protect Bash Pipelines Against SIGPIPE (141)**:
   - Always wrap pipelines: `(tshark ... 2>/dev/null || true) | head -n1`.
6. **Double-Quote Complex Values in `config.env`**:
   - `CAPTURE_FILTER="(udp port 67 or udp port 68) or arp"`
7. **Strict Mode Array Invocations**:
   - Under `IFS=$'\n\t'`, run multi-word commands as arrays: `CMD=("docker" "compose"); "${CMD[@]}" up`.
8. **The Upstream WAN Server Standard (The Kea Triad: `kea-dhcp4` + `kea-dhcp6` + `radvd`)**:
   - **Primary Standard**: Mandate the **Kea Triad (`kea-dhcp4` + `kea-dhcp6` + `radvd`)** for Upstream WAN services in router, gateway (DUT), and carrier-grade dual-stack test environments.
     - `kea-dhcp4`: Carrier-grade DHCPv4 server managing WAN IP pools, subnet masks, default gateways, and DNS servers.
     - `kea-dhcp6`: Carrier-grade DHCPv6 server supporting IA_NA (WAN IPv6 address allocation), IA_PD (Prefix Delegation pools per RFC 3633 / RFC 8415 for delegating prefixes such as `/56` or `/60` to CPE routers/DUT), Rapid Commit, and AFTR (DS-Lite RFC 6333 Option 64).
     - `radvd`: Autonomous Router Advertisement daemon providing granular RFC 4861 / RFC 8106 control (`AdvManagedFlag on`, `AdvOtherConfigFlag on`, `AdvAutonomous on/off`, configurable min/max RA intervals).
   - **Automated Fallback**: Provide automated fallback to `dnsmasq` when Kea is not installed or encounters socket binding errors, ensuring continuous lab availability and lightweight host-only testing.
   - **Kea 3.0+ Mandatory Safeguards**:
     - *Log Path Sandbox Trap*: In Kea 3.0+, configuring non-standard output file paths fails with `COMMAND_PROCESS_ERROR2: invalid path in output, supported path is '/var/log/kea'`. Always configure `"output": "stdout"` in Kea json logger configs so the launcher safely redirects output to `${LOG_DIR}/kea-dhcp*.log`.
     - *AppArmor Profile Lock Trap*: Always unbind host AppArmor profiles for Kea (`apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp* 2>/dev/null || true`) and ensure `/run/kea`, `/run/lock/kea`, `${STATE_DIR}/kea` exist with full write permissions (`0777`).
     - *Netns Socket Readiness Trap (`DHCPSRV_NO_SOCKETS_OPEN`)*: Always ensure interface `eth0` in `ns-wan` has a valid link-local address (`fe80::.../64`) and IPv6 forwarding enabled before launching Kea.

---

## 5. References & Templates Library

### Sub-Documentation
- [references/principles_and_architecture.md](references/principles_and_architecture.md): Core philosophies, topology models, and directory structure.
- [references/common_library_guide.md](references/common_library_guide.md): Comprehensive API reference for `scripts/lib/common.sh`.
- [references/topology_and_lifecycle.md](references/topology_and_lifecycle.md): Topology setup, rollback traps, and interface restoration.
- [references/dhcp_and_namespace_isolation.md](references/dhcp_and_namespace_isolation.md): Namespace DHCP client (`udhcpc`/`dhclient`), Standard Kea Triad WAN Server Architecture (`kea-dhcp4` + `kea-dhcp6` + `radvd` with IA_PD & IA_NA), automated dnsmasq fallback, and standard profile recipes.
- [references/pcap_verification_and_evidence.md](references/pcap_verification_and_evidence.md): Evidence-based verification, ASCII timeline, and tshark filtering.
- [references/cli_standards_and_pitfalls.md](references/cli_standards_and_pitfalls.md): The 4 help traps, 6-section usage format, and Canonical CLI pattern.
- [references/troubleshooting_and_gotchas.md](references/troubleshooting_and_gotchas.md): Common network issues, kernel routing tricks, and firewall gotchas.
- [references/framework_guide_full.md](references/framework_guide_full.md): Full original text of the Network Test Lab Framework Guide.

### Ready-to-Use Templates
- [templates/config.env.example](templates/config.env.example): Standard configuration environment template.
- [templates/gitignore.template](templates/gitignore.template): Standard `.gitignore`.
- [templates/common.sh](templates/common.sh): Complete production helper library.
- [templates/kea-dhcp4.conf.in](templates/kea-dhcp4.conf.in): Standard Kea DHCPv4 configuration template.
- [templates/kea-dhcp6.conf.in](templates/kea-dhcp6.conf.in): Standard Kea DHCPv6 configuration template with IA_NA and IA_PD prefix delegation.
- [templates/radvd.conf.in](templates/radvd.conf.in): Standard Router Advertisement daemon template.
- [templates/udhcpc.script](templates/udhcpc.script): Namespace-safe DHCP configuration event script.
- [templates/setup.sh](templates/setup.sh): Topology setup script with auto-rollback trap.
- [templates/cleanup.sh](templates/cleanup.sh): Idempotent teardown and NIC restoration script.
- [templates/capture.sh](templates/capture.sh): Background packet capture lifecycle manager.
- [templates/show_state.sh](templates/show_state.sh): Runtime observer with stale PID detection.
- [templates/diagnose.sh](templates/diagnose.sh): Non-destructive pre-flight diagnostic runner.
- [templates/scenario.sh](templates/scenario.sh): Modular multi-phase automated test runner.
- [templates/verify_compliance.sh](templates/verify_compliance.sh): Dual-layer PCAP verification script with ASCII timeline.
- [templates/canonical_cli.sh](templates/canonical_cli.sh): Canonical CLI pattern boilerplate.

### Executable Tools
- [scripts/scaffold_lab.sh](scripts/scaffold_lab.sh): One-touch project generator script.
