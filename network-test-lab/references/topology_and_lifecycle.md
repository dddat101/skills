# Topology Setup & Lifecycle Management

This document covers the end-to-end lifecycle of a Network Test Lab, including automated topology creation, rollback safety traps, state persistence, and idempotent teardown.

---

## 1. Setup Architecture (`scripts/setup.sh`)

### 1.1. Auto-Rollback Trap Pattern
Network configuration in Linux can fail midway (e.g. invalid interface name, bridge allocation collision, IP conflict). Without auto-rollback, the host is left with dangling bridges, half-configured namespaces, and disabled NetworkManager interfaces.

The standard pattern arms an `ERR` trap during setup and disarms it upon success:

```bash
SETUP_ACTIVE=0

rollback_setup() {
    local exit_code="$1"
    local line_number="$2"
    if (( SETUP_ACTIVE == 0 )); then return; fi

    trap - ERR
    log_error "Setup failed near line ${line_number}; rolling back topology..."
    "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1 || true
    log_error "Rollback complete. Original error code: ${exit_code}"
    exit "${exit_code}"
}

# In main():
SETUP_ACTIVE=1
trap 'rollback_setup $? ${LINENO}' ERR

# ... configuration steps ...

SETUP_ACTIVE=0
trap - ERR
log_success "Topology setup successfully completed!"
```

### 1.2. Virtual Simulation Setup (`--virtual`)
In virtual mode, software routers (`ns-dut`) emulate physical gateway behavior using kernel routing and masquerade NAT:

```bash
setup_virtual_dut() {
    local ns_dut="${DUT_NS:-ns-dut}"
    log_info "Creating simulated DUT router ${ns_dut}..."
    ns_create "${ns_dut}"

    create_veth_to_ns "${ns_dut}" "veth-dutwan" "eth-wan" "${WAN_BRIDGE}" "${DUT_WAN_IP:-10.10.0.1}/${WAN_PREFIX:-24}" ""
    create_veth_to_ns "${ns_dut}" "veth-dutlan" "eth-lan" "${LAN_BRIDGE}" "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" ""

    # Enable IPv4 forwarding and NAT
    ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -F 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -t nat -F 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -t nat -A POSTROUTING -o eth-wan -j MASQUERADE 2>/dev/null || true
    ip -n "${ns_dut}" route replace default via "${WAN_SERVER_IP:-10.10.0.10}" dev eth-wan 2>/dev/null || true
}
```

### 1.3. Runtime State Persistence
Upon successful creation, `setup.sh` records topology parameters to `state/topology_state.env`:

```bash
cat >"${STATE_DIR}/topology_state.env" <<EOF
TOPOLOGY_MODE='${mode}'
LAB_ROLE='${role}'
SETUP_TIMESTAMP='$(date -Iseconds)'
WAN_BRIDGE='${WAN_BRIDGE}'
LAN_BRIDGE='${LAN_BRIDGE}'
WAN_NS='${WAN_NS:-ns-wan}'
LAN_NS='${LAN_NS:-ns-lan}'
DUT_NS='${DUT_NS:-ns-dut}'
WAN_SERVER_IP='${WAN_SERVER_IP:-10.10.0.10}'
DUT_WAN_IP='${DUT_WAN_IP:-10.10.0.1}'
DUT_LAN_IP='${DUT_LAN_IP:-192.168.1.1}'
EOF
```

---

## 2. Teardown Architecture (`scripts/cleanup.sh`)

### 2.1. 4 Golden Rules of Cleanup
1. **Idempotency**: Running `cleanup.sh` multiple times consecutively must never fail.
2. **Interface Restoration vs Isolation**:
   - Default: Restore interfaces (`-r / --restore`), handing them back to NetworkManager and triggering DHCP if cable is plugged (`LOWER_UP`).
   - Isolated: Down mode (`-d / --down`), keeping NICs flushed and unmanaged for CI/CD runners.
3. **Non-Destructive Data Purging**:
   - `./scripts/cleanup.sh logs`: Purges logs without touching network or running servers.
   - `./scripts/cleanup.sh captures`: Purges `.pcap` files without destroying namespaces.
   - `./scripts/cleanup.sh data`: Purges both logs and captures.
4. **All-Inclusive Teardown (`-a / --all`)**: Tears down topology and purges state, logs, and captures.

### 2.2. Standard Teardown Order
Teardown must execute in exact reverse order of setup to avoid kernel resource locks:
1. **Stop packet captures**: Flush buffers and stop background capture daemons.
2. **Stop application daemons**: Stop servers recorded in `state/*.pid` via 3-tier escalation.
3. **Kill namespace processes**: `pkill -TERM` on any lingering `tcpdump`, `udhcpc`, or `dhclient` inside target namespaces.
4. **Delete veth peers**: Deleting host-side veth endpoints automatically removes peer ends in namespaces.
5. **Delete network namespaces**: `ip netns del <ns>`.
6. **Tear down bridges**: Flush, set link down, and delete bridges.
7. **Restore or isolate physical NICs**: Reconnect to NetworkManager or leave down.
8. **Purge runtime state**: Remove `.pid`, `.leases`, and `topology_state.env`.
