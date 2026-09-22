# Practical Pitfalls & Troubleshooting Runbook

This runbook compiles common traps, kernel behaviors, and troubleshooting patterns encountered when engineering Linux Network Test Labs.

---

## 1. NetworkManager Interference & Host Safety

### Symptom:
Connecting a USB-to-Ethernet adapter triggers NetworkManager on Ubuntu/Debian to request DHCP or assign a link-local IPv4/IPv6 address and inject a default route into the host routing table.

### Danger:
If `setup.sh` uses this adapter directly, host traffic may reroute through the isolated test bed, severing Internet/SSH connectivity to the host machine.

### Framework Fix:
`assert_safe_test_if` in `common.sh`:
1. Validates that the interface does **not** carry the host default gateway (`ip route show default`).
2. Automatically sets the interface to unmanaged and flushes existing addresses:
   ```bash
   command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
   ip addr flush dev "${iface}" 2>/dev/null || true
   ```

---

## 2. Interface State Management After Cleanup

### The Dilemma:
Leaving physical interfaces in `DOWN` state causes network disconnects for developers. Conversely, leaving test IPs intact causes subnet collisions.

### Framework Solution:
`cleanup.sh` supports two explicit modes:
1. **Restore Mode (Default, `-r / --restore`)**:
   - Detaches interface from test bridge (`ip link set dev <iface> nomaster`).
   - Flushes test IP addresses.
   - Sets link `UP`.
   - Restores NetworkManager: `nmcli device set <iface> managed yes autoconnect yes`.
   - If cable link is detected (`LOWER_UP`), triggers non-blocking background DHCP:
     ```bash
     dhclient -4 -nw "${iface}" 2>/dev/null || true
     ```
2. **Isolation Mode (`-d / --down / --no-restore`)**:
   - Flushes IP and sets interface `DOWN`. Essential for CI/CD runners and regression tests.

---

## 3. Virtual DUT Mock Routing Trick

### Challenge:
Simulating a multi-interface hardware router (e.g. bridging WAN and LAN, forwarding multicast IGMP, and performing L3 NAT) often requires running daemons like `pimd`, `smcroute`, or `quagga`.

### Kernel Trick:
Inside the `ns-dut` namespace, create an internal bridge `br-dut` connecting `dut-wan` and `dut-lan`, and assign **both** gateway IP addresses directly to `br-dut`:
```bash
# Inside ns-dut:
ip link add name br-dut type bridge
ip link set dev eth-wan master br-dut
ip link set dev eth-lan master br-dut
ip addr add 10.10.0.1/24 dev br-dut
ip addr add 192.168.1.1/24 dev br-dut
ip link set dev br-dut up
sysctl -w net.ipv4.ip_forward=1
```
This enables seamless L2 bridging and L3 routing simultaneously without installing third-party routing daemons!

---

## 4. DUT Gateway Firewall: WAN Input Drop

### Problem:
Commercial routers/CPEs have a strict firewall on the WAN port (`drop` on `INPUT` chain). When mock servers respond to DHCP (UDP 67/68) or TR-069/CWMP Connection Requests, the router drops incoming packets at the WAN boundary.

### DUT Configuration Fix:
Ensure appropriate rules are configured on the DUT:
```bash
# nftables on DUT WAN interface:
iifname "eth-wan" udp sport 67 udp dport { 67, 68 } counter accept

# iptables on DUT:
iptables -I INPUT -i eth-wan -p udp --sport 67 --dport 67:68 -j ACCEPT
```

---

## 5. Bash Strict Mode Traps & Solutions

### 5.1. `printf` Option Bug (`printf: --: invalid option`)
- **Trap**: `printf '--- [SECTION] ---\n'` interprets leading `-` as a CLI option.
- **Fix**: Use `print_section "SECTION"` or `printf '%s\n' '--- [SECTION] ---'`.

### 5.2. Strict `IFS=$'\n\t'` with Command Strings
- **Trap**: Under strict `IFS`, whitespace is not a word separator.
  ```bash
  CMD="docker compose"
  ${CMD} up  # Fails: bash searches for a binary named "docker compose" with space!
  ```
- **Fix**: Always use Bash arrays:
  ```bash
  CMD=("docker" "compose")
  "${CMD[@]}" up
  ```

### 5.3. Invalid `local` Variable Scope
- **Trap**: Using `local var="value"` outside a function body causes `bash: local: can only be used in a function`.
- **Fix**: Keep script-level variables plain or wrap all logic in `main()`.

### 5.4. Stale PID Files
- **Trap**: Checking only `[[ -f pidfile.pid ]]` reports dead services as running after a system reboot or crash.
- **Fix**: Use `is_pidfile_running` which checks `kill -0 "$pid"` and `/proc/$pid`.
