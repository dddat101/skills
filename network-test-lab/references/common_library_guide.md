# Common Helper Library (`common.sh`)

Every script in `scripts/` loads `scripts/lib/common.sh`. This library provides standard primitives for logging, process supervision, network namespace isolation, host safety, and packet verification.

---

## 1. Library Path & Strict Mode Initialization

```bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
readonly CONFIG_FILE="${PROJECT_ROOT}/config.env"
readonly LOG_TAG="LAB-FRAMEWORK"
```

---

## 2. API Reference by Category

### 2.1. Logging & Formatting

| Function | Description | Example |
| :--- | :--- | :--- |
| `log_info "msg"` | Cyan/Green informational log | `log_info "Starting bridge..."` |
| `log_success "msg"` | Green `[PASS]` badge for passed steps | `log_success "DUT responded to ping"` |
| `log_warn "msg"` | Yellow `[WARN]` to stderr | `log_warn "Cache missing, falling back"` |
| `log_error "msg"` | Red `[ERROR]` to stderr | `log_error "Interface not found"` |
| `log_step "msg"` | Cyan banner `===> STEP` | `log_step "Phase 1: DHCP handshake"` |
| `log_debug "msg"` | Blue output when `DEBUG=1` or `VERBOSE=1` | `log_debug "Socket poll attempt #3"` |
| `die "msg"` | Logs error and exits with code 1 | `die "Fatal network condition"` |
| `print_header "title"` | Formats bordered 2-line header | `print_header "SETUP TOPOLOGY"` |
| `print_section "title"` | Safely prints `--- [title] ---` avoiding printf `-` bug | `print_section "SECTION 1: DISCOVERY"` |

### 2.2. Privilege & Tool Availability

| Function | Description |
| :--- | :--- |
| `require_root` | Checks `EUID == 0`. Aborts with `die` if non-root. Never call before help parsing! |
| `is_root` | Returns boolean status `(( EUID == 0 ))`. |
| `require_command <cmd>` | Verifies binary is installed in `$PATH`, fails fatally if missing. |
| `check_command <cmd>` | Soft boolean check: returns 0 if command exists, 1 if missing. |

### 2.3. Config Loading & Runtime Directories

```bash
load_config [path]
```
- Auto-copies `config.env.example` to `config.env` if missing.
- Sources environment variables.
- Auto-detects local Python virtual environment (`.venv/bin/python3`).
- Resolves paths relative to `PROJECT_ROOT`.
- Invokes `ensure_runtime_dirs`.

```bash
ensure_runtime_dirs
```
- Creates `captures/`, `logs/`, and `state/`.
- Sets mode `0777` (`chmod -R a+rw`) to prevent permission collisions between `sudo` and normal user accounts.

```bash
clean_logs
clean_captures
```
- Non-destructive cleanup helpers that preserve `.gitkeep` placeholders.

### 2.4. Host Safety & Network Protection

```bash
assert_safe_test_if <iface>
```
1. Validates interface exists.
2. Rejects loopback (`lo`).
3. Rejects any interface carrying host's default route (`ip route show default`).
4. Detects active host IP and unmanages NetworkManager:
   ```bash
   command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
   ip addr flush dev "${iface}" 2>/dev/null || true
   ```

### 2.5. Network Namespaces & Bridges

| Function | Signature | Description |
| :--- | :--- | :--- |
| `ns_exists` | `ns_exists <ns_name>` | Checks if netns exists in `ip netns list`. |
| `ns_create` | `ns_create <ns_name>` | Creates netns and brings up loopback (`lo`). |
| `bridge_create` | `bridge_create <br_name>` | Creates Linux bridge with STP=0, multicast snooping=0, IPv6 disabled. |
| `attach_physical_to_bridge` | `attach_physical_to_bridge <iface> <bridge>` | Validates safety, unmanages NM, and attaches physical NIC as bridge slave. |
| `create_veth_to_ns` | `create_veth_to_ns <ns> <host_veth> <ns_veth> <bridge> <cidr> [gw]` | Creates veth pair, attaches host end to bridge, moves other end to netns with IP and default route. |
| `exec_in_ns` | `exec_in_ns <ns> <cmd...>` | Runs command inside netns if specified, otherwise on host. |
| `namespace_ip` | `namespace_ip [ns] [iface]` | Extracts first IPv4 address assigned to interface in netns. |
| `namespace_mac` | `namespace_mac [ns] [iface]` | Reads hardware MAC address from sysfs. |

### 2.6. Interface Recovery & Cleanup

```bash
restore_physical_interface <iface>
```
- Detaches NIC from bridge (`nomaster`).
- Flushes IP addresses.
- Sets link `UP`.
- Re-enables NetworkManager management & autoconnect (`nmcli device set <iface> managed yes`).
- Triggers non-blocking background DHCP (`dhclient -4 -nw <iface>`) if link carrier is active (`LOWER_UP`).

```bash
tear_down_physical_interface <iface>
```
- Alternative isolation mode: flushes IP, brings link `DOWN`, and unbinds from bridge.

### 2.7. Deterministic Synchronization & Socket Polling

```bash
is_port_listening <port> [host] [ns]
```
- Performs a 0.5s non-blocking Python socket probe.

```bash
wait_for_port <port> [host] [timeout] [ns]
```
- Polls until socket is accepting connections or timeout is reached. Eliminates race conditions and hardcoded sleeps.

```bash
wait_for_http <url> [expected_code] [timeout] [ns]
```
- Polls HTTP endpoint via `curl -sk` until matching status code is returned.

### 2.8. Process Supervision & Daemon Management

```bash
start_daemon <pid_file> <log_file> <service_name> [ns] <command...>
```
- Verifies not already running via `is_pidfile_running`.
- Spawns background process via `nohup` (optionally inside `netns`).
- Stores PID and ensures file permissions are `0666`.
- Asserts process didn't crash within 200ms.

```bash
stop_pidfile <pid_file> [service_name]
```
- 3-tier escalating termination:
  1. `SIGINT` (allows log flushing).
  2. `SIGTERM` (graceful exit within 1.5s).
  3. `SIGKILL` (forces termination if hung).
- Deletes stale `.pid` file.

```bash
stop_process_by_pattern <pattern> [name]
```
- Terminates orphan background processes by regex match with escalating signals.

### 2.9. PCAP & Telemetry Utilities

```bash
get_latest_pcap
```
- Resolves newest `.pcap` file from `state/last_capture.env` or by modification time in `captures/`.

```bash
format_bytes <bytes>
```
- Formats raw byte integer into human-readable unit (`B`, `KB`, `MB`, `GB`).

```bash
detect_tshark_field <fields_cache> <candidate_1> [candidate_2...]
```
- Resolves correct protocol filter field across Wireshark 3.x and 4.x versions.
