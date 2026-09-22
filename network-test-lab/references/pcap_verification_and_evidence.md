# PCAP Verification & Evidence Engine

Network verification cannot rely solely on command exit codes (e.g. ping or curl). The framework mandates evidence-based verification using packet capture files (`.pcap`) and post-test packet inspection via `tshark`.

---

## 1. Packet Capture Architecture: `tcpdump` vs. `tshark`

### 1.1. The `dumpcap` Privilege Drop Trap
On Debian/Ubuntu systems, Wireshark's underlying capture utility (`dumpcap`) automatically drops root privileges to the invoking user or unprivileged group `wireshark` when invoked under `sudo`.
If the user's home or project directory has restrictive permissions (`chmod 750`), `dumpcap` fails with:
```text
tshark: The file to which the capture would be saved (...) could not be opened: Permission denied.
```

### 1.2. The Production Standard
1. **Background Capture**: Exclusively use **`tcpdump`** with flags:
   - `-U`: Packet-buffered mode (flushes packets immediately to disk).
   - `-s 0`: Snarf full packet payload (no truncation).
   - `-w <pcap_file>`: Write raw pcap.
2. **Directory Permissions**: Ensure runtime directories are created with `0777` permissions.
3. **Analysis & Verification**: Use **`tshark`** exclusively for post-capture inspection.

```bash
# capture.sh start pattern:
nohup ip netns exec "${NS_CLIENT}" tcpdump \
    -ni "${CLIENT_IF}" -s 0 -U \
    -w "${pcap_file}" > "${log_file}" 2>&1 &
```

---

## 2. Robust `tshark` Scripting Guidelines

### 2.1. SIGPIPE (Exit Code 141) Prevention
Under Bash strict mode (`set -Eeuo pipefail`), piping output into commands that exit early (e.g. `head -n1` or `awk '...; exit'`) triggers a `SIGPIPE` signal on the upstream command. Under `pipefail`, this causes the entire script to abort with exit code 141.

#### Required Pattern:
Always wrap pipelines in subshells with fallback:
```bash
# Correct:
first_frame="$((tshark -r "${pcap_file}" -T fields -e frame.number 2>/dev/null || true) | head -n1)"

# Dangerous (will abort script with exit code 141):
first_frame="$(tshark -r "${pcap_file}" -T fields -e frame.number | head -n1)"
```

### 2.2. Never Quote IP Addresses in Display Filters (`-Y`)
In Wireshark 4.2+, quoting an IPv4 address in display filters triggers a syntax rejection:
```text
tshark: IPv4 address cannot be converted from a string
```

- **Forbidden**: `tshark -Y 'ip.src == "10.10.0.1"'`
- **Mandatory**: `tshark -Y 'ip.src == 10.10.0.1'`

### 2.3. Multi-Version Wireshark Compatibility
Field names differ across Wireshark releases (e.g. `_ws.col.Source` vs `ip.src`). Use `detect_tshark_field` from `common.sh` when querying custom column fields dynamically:

```bash
fields_cache="$(tshark -G fields 2>/dev/null || true)"
target_field="$(detect_tshark_field "${fields_cache}" "http.response.code" "http.response_code" || echo "http.response.code")"
```

---

## 3. Visual ASCII Packet Timeline

The verification script generates an aligned ASCII timeline table for terminal output and CI logs:

```bash
print_pcap_timeline() {
    local pcap_file="$1"
    [[ -f "${pcap_file}" && -s "${pcap_file}" ]] || return 0

    printf '\n========================================================================================\n'
    printf '                          PACKET TIMELINE EVIDENCE                               \n'
    printf '========================================================================================\n'
    printf '%-6s | %-12s | %-24s | %-24s | %-20s\n' "Frame" "Time (s)" "Source IP" "Destination IP" "Protocol / Info"
    printf '%s\n' "----------------------------------------------------------------------------------------"

    # shellcheck disable=SC2016
    tshark -r "${pcap_file}" \
        -T fields \
        -e frame.number -e frame.time_relative -e _ws.col.Source -e _ws.col.Destination -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null | \
        awk -F '\t' '{ printf "%-6s | %-12.4f | %-24s | %-24s | %-10s %s\n", $1, $2, $3, $4, $5, $6 }' | head -n 40 || true

    printf '========================================================================================\n\n'
}
```

---

## 4. Dual-Layer Verification Model

A robust test checks compliance across two independent planes:

1. **Wire Layer (PCAP)**:
   - Packet existence and sequencing.
   - Handshake flags (SYN, ACK, TLS Client Hello).
   - Expected status codes (HTTP 200, DHCP ACK, IGMP Join).
   - Traffic isolation: Zero frames matching unauthorized source IPs.

2. **Application / Audit Layer (JSONL)**:
   - Server or client daemon internal state records (`logs/*audit*.jsonl`).
   - Session handshake confirmations.
   - Database mutations or configuration updates.

3. **Definitive Exit Code**:
   - `exit 0`: 100% of test assertions passed.
   - `exit 1`: One or more assertions failed.
