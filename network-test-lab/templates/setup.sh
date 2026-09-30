#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - TOPOLOGY SETUP
# Supports Virtual Multi-Endpoint Simulation and Physical Benchmarking
# Refactored with Bash Defensive Programming Standards
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0
DRY_RUN=0

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Topology Setup
==================================================================

Description:
  Initializes network namespaces, virtual interfaces, Linux bridges,
  and rate-limiting queue disciplines required to test Wire-rate
  throughput, WAN-to-LAN rate mismatch burst absorption, and QoS.

Usage:
  sudo ./scripts/setup.sh [OPTIONS]

Options:
  --virtual, -v
      Pure software simulation using isolated Linux network namespaces:
      ns-wan, ns-dut, ns-pc (1G), ns-stb (100M rate-limited),
      ns-wlan2g, ns-wlan5g, ns-wlan6g, ns-phone1, ns-phone2. [Default]

  --single, -s
      Single-PC Dual-NIC physical topology connected to external DUT.

  --lan-dhcp, --dhcp-client
      Enable dynamic DHCP client on LAN endpoints (leases from DUT br0).

  --no-lan-dhcp, --static-lan
      Keep static IP addresses on LAN endpoints [Default].

  --wan-dhcp
      Enable upstream WAN DHCP server in ns-wan to lease IP to DUT [Default].

  --no-wan-dhcp
      Disable upstream WAN DHCP server (requires static WAN on DUT).

  --dry-run, -n
      Preview network topology actions without creating interfaces.

  -h, --help
      Show this help message and exit.

Examples:
  sudo ./scripts/setup.sh --virtual
  sudo ./scripts/setup.sh --single
  sudo ./scripts/setup.sh --single --lan-dhcp
  ./scripts/setup.sh --dry-run
==================================================================
EOF
}

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

# Defensive helper: Clean any lingering interfaces to ensure idempotency
clean_stale_interfaces() {
    log_info "Ensuring clean state for virtual interfaces..."
    local stale_veths=(
        "veth-wan" "veth-dutwan"
        "veth-dut-pc" "veth-dut-stb"
        "veth-dut-w2g" "veth-dut-w5g" "veth-dut-w6g"
        "veth-dut-ph1" "veth-dut-ph2"
        "veth-client"
    )
    for dev in "${stale_veths[@]}"; do
        if ip link show dev "${dev}" >/dev/null 2>&1; then
            ip link del dev "${dev}" 2>/dev/null || true
        fi
    done
}

setup_virtual_topology() {
    log_info "Deploying virtual multi-endpoint topology..."

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would create namespaces: ns-wan, ns-dut, ns-pc, ns-stb, ns-wlan2g/5g/6g, ns-phone1/phone2"
        log_info "[DRY-RUN] Would interconnect WAN link: ${WAN_SERVER_IP:-203.0.113.1}/${WAN_PREFIX:-24} <-> ${DUT_WAN_IP:-203.0.113.129}/${WAN_PREFIX:-24}"
        log_info "[DRY-RUN] Would configure br-lan: ${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24} with NAT and multicast forwarding"
        log_info "[DRY-RUN] Would shape veth-dut-stb with TBF: rate=${STB_RATE_LIMIT:-100mbit}, burst=${STB_QUEUE_BURST_BUFFER:-256k}"
        return 0
    fi

    # 1. Clean stale virtual devices for idempotency
    clean_stale_interfaces

    # 2. Create Namespaces
    local ns_list=(
        "${WAN_NS:-ns-wan}"
        "${DUT_NS:-ns-dut}"
        "${PC_NS:-ns-pc}"
        "${STB_NS:-ns-stb}"
        "${WLAN2G_NS:-ns-wlan2g}"
        "${WLAN5G_NS:-ns-wlan5g}"
        "${WLAN6G_NS:-ns-wlan6g}"
        "${PHONE1_NS:-ns-phone1}"
        "${PHONE2_NS:-ns-phone2}"
    )

    for ns in "${ns_list[@]}"; do
        ns_create "${ns}"
    done

    # 3. Interconnect ns-wan <-> ns-dut (WAN Uplink)
    log_info "Connecting WAN link (ns-wan <-> ns-dut)..."
    ip link add name "veth-wan" type veth peer name "veth-dutwan"
    ip link set "veth-wan" netns "${WAN_NS:-ns-wan}"
    ip link set "veth-dutwan" netns "${DUT_NS:-ns-dut}"

    # Configure WAN endpoint
    ip -n "${WAN_NS:-ns-wan}" link set "veth-wan" name "eth0"
    ip -n "${WAN_NS:-ns-wan}" link set "eth0" up
    ip -n "${WAN_NS:-ns-wan}" addr add "${WAN_SERVER_IP:-203.0.113.1}/${WAN_PREFIX:-24}" dev eth0
    ip -n "${WAN_NS:-ns-wan}" -6 addr add "${WAN_IPV6_CIDR:-2001:db8:10::1/64}" dev eth0 nodad 2>/dev/null || true
    ip -n "${WAN_NS:-ns-wan}" route replace "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
    ip -n "${WAN_NS:-ns-wan}" route replace default via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
    ip -n "${WAN_NS:-ns-wan}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true

    # Configure DUT WAN endpoint
    ip -n "${DUT_NS:-ns-dut}" link set "veth-dutwan" name "eth-wan"
    ip -n "${DUT_NS:-ns-dut}" link set "eth-wan" up
    ip -n "${DUT_NS:-ns-dut}" addr add "${DUT_WAN_IP:-203.0.113.129}/${WAN_PREFIX:-24}" dev eth-wan
    ip -n "${DUT_NS:-ns-dut}" -6 addr add "${DUT_WAN_IPV6:-2001:db8:10::2/64}" dev eth-wan nodad 2>/dev/null || true
    ip -n "${DUT_NS:-ns-dut}" route replace default via "${WAN_SERVER_IP:-203.0.113.1}" dev eth-wan

    # Apply 1 Gbps Gigabit WAN rate limits (Uplink and Downlink emulation)
    local wan_rate="${WAN_RATE_LIMIT:-1000mbit}"
    local wan_burst="${WAN_BURST_BUFFER:-512kb}"
    log_info "Configuring 1 Gbps WAN link shaping on eth0 and eth-wan..."
    ip netns exec "${WAN_NS:-ns-wan}" tc qdisc replace dev eth0 root tbf \
        rate "${wan_rate}" burst "${wan_burst}" latency 50ms 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" tc qdisc replace dev eth-wan root tbf \
        rate "${wan_rate}" burst "${wan_burst}" latency 50ms 2>/dev/null || true

    # 4. Configure DUT LAN Bridge & Routing/NAT
    log_info "Configuring DUT LAN Bridge (br-lan) & Hardware-NAT emulation..."
    ip -n "${DUT_NS:-ns-dut}" link add name "br-lan" type bridge
    ip -n "${DUT_NS:-ns-dut}" link set "br-lan" up
    ip -n "${DUT_NS:-ns-dut}" addr add "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" dev br-lan
    ip -n "${DUT_NS:-ns-dut}" -6 addr add "${DUT_LAN_IPV6:-2001:db8:100::1/64}" dev br-lan nodad 2>/dev/null || true

    # Enable kernel IP forwarding and Multicast forwarding in DUT
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv4.conf.all.mc_forwarding=1 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv4.conf.br-lan.mc_forwarding=1 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv4.conf.eth-wan.mc_forwarding=1 2>/dev/null || true

    # Enable Bridge IGMP Snooping
    ip netns exec "${DUT_NS:-ns-dut}" sysctl -q -w net.ipv4.conf.br-lan.force_mld_version=0 2>/dev/null || true
    ip -n "${DUT_NS:-ns-dut}" link set "br-lan" type bridge mcast_snooping 1 2>/dev/null || true

    # Setup NAT & Forwarding rules (Allow all lab test traffic bidirectional)
    ip netns exec "${DUT_NS:-ns-dut}" iptables -F 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" iptables -t nat -F 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" iptables -t nat -A POSTROUTING -o eth-wan -j MASQUERADE 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" iptables -P FORWARD ACCEPT 2>/dev/null || true
    ip netns exec "${DUT_NS:-ns-dut}" iptables -A FORWARD -j ACCEPT 2>/dev/null || true
    ip -n "${DUT_NS:-ns-dut}" route replace 224.0.0.0/4 dev br-lan 2>/dev/null || true

    # Helper function to attach client endpoint to br-lan
    connect_client() {
        local client_ns="$1"
        local dev_dut="$2"
        local ip_addr="$3"

        if ip link show dev "${dev_dut}" >/dev/null 2>&1; then
            ip link del dev "${dev_dut}" 2>/dev/null || true
        fi

        ip link add name "${dev_dut}" type veth peer name "veth-client"
        ip link set "${dev_dut}" netns "${DUT_NS:-ns-dut}"
        ip link set "veth-client" netns "${client_ns}"

        # Attach DUT side to br-lan
        ip -n "${DUT_NS:-ns-dut}" link set "${dev_dut}" master br-lan
        ip -n "${DUT_NS:-ns-dut}" link set "${dev_dut}" up

        # Configure Client side
        ip -n "${client_ns}" link set "veth-client" name "eth0"
        ip -n "${client_ns}" link set "eth0" up
        ip -n "${client_ns}" addr add "${ip_addr}/${LAN_PREFIX:-24}" dev eth0
        ip -n "${client_ns}" route replace default via "${DUT_LAN_IP:-192.168.1.1}" dev eth0
    }

    # 5. Attach PC Client (1 Gbps Gigabit Ethernet)
    log_info "Connecting PC LAN client (ns-pc: ${PC_IP:-192.168.1.10})..."
    connect_client "${PC_NS:-ns-pc}" "veth-dut-pc" "${PC_IP:-192.168.1.10}"
    local pc_rate="${PC_RATE_LIMIT:-1000mbit}"
    local pc_burst="${PC_BURST_BUFFER:-512kb}"
    ip netns exec "${DUT_NS:-ns-dut}" tc qdisc replace dev veth-dut-pc root tbf \
        rate "${pc_rate}" burst "${pc_burst}" latency 50ms 2>/dev/null || true

    # 6. Attach IPTV STB Client (100 Mbps Fast Ethernet Link Mismatch)
    log_info "Connecting IPTV STB client (ns-stb: ${STB_IP:-192.168.1.20}) with 100M rate limit..."
    connect_client "${STB_NS:-ns-stb}" "veth-dut-stb" "${STB_IP:-192.168.1.20}"

    # Apply Token Bucket Filter (TBF) on DUT port connected to STB with deep queue buffer for burst absorption
    local rate_limit="${STB_RATE_LIMIT:-100mbit}"
    local burst_buf="${STB_QUEUE_BURST_BUFFER:-512kb}"
    local queue_limit="${STB_QUEUE_LIMIT:-4mb}"
    log_info "Configuring Traffic Control on veth-dut-stb: rate=${rate_limit}, burst=${burst_buf}, limit=${queue_limit}..."
    ip netns exec "${DUT_NS:-ns-dut}" tc qdisc replace dev veth-dut-stb root tbf \
        rate "${rate_limit}" burst "${burst_buf}" limit "${queue_limit}" 2>/dev/null || true
    ip -n "${DUT_NS:-ns-dut}" link set dev veth-dut-stb txqueuelen 10000 2>/dev/null || true
    ip -n "${STB_NS:-ns-stb}" link set dev eth0 txqueuelen 10000 2>/dev/null || true

    # Tune network stack buffer ceilings and backlog queues to avoid socket drops during micro-bursts
    for ns in "${WAN_NS:-ns-wan}" "${DUT_NS:-ns-dut}" "${STB_NS:-ns-stb}" "${PC_NS:-ns-pc}"; do
        ip netns exec "${ns}" sysctl -q -w net.core.rmem_max=16777216 2>/dev/null || true
        ip netns exec "${ns}" sysctl -q -w net.core.wmem_max=16777216 2>/dev/null || true
        ip netns exec "${ns}" sysctl -q -w net.core.netdev_max_backlog=10000 2>/dev/null || true
    done

    # 7. Attach Simulated Wireless Clients (2.4 GHz, 5 GHz, 6 GHz)
    log_info "Connecting Tri-band wireless clients (2.4GHz, 5GHz, 6GHz)..."
    connect_client "${WLAN2G_NS:-ns-wlan2g}" "veth-dut-w2g" "${WLAN2G_IP:-192.168.1.31}"
    connect_client "${WLAN5G_NS:-ns-wlan5g}" "veth-dut-w5g" "${WLAN5G_IP:-192.168.1.32}"
    connect_client "${WLAN6G_NS:-ns-wlan6g}" "veth-dut-w6g" "${WLAN6G_IP:-192.168.1.33}"

    # 8. Attach Wi-Fi Phones (VoIP Clients)
    log_info "Connecting Wi-Fi phone clients (phone1, phone2)..."
    connect_client "${PHONE1_NS:-ns-phone1}" "veth-dut-ph1" "${PHONE1_IP:-192.168.1.41}"
    connect_client "${PHONE2_NS:-ns-phone2}" "veth-dut-ph2" "${PHONE2_IP:-192.168.1.42}"

    log_success "Virtual multi-endpoint topology successfully established."
}

setup_physical_topology() {
    log_info "Deploying physical Multi-Port / Hardware DUT topology..."
    local wan_if="${WAN_IF:-}"
    local lan_if="${PC_IF:-${LAN_IF:-}}"
    local stb_if="${STB_IF:-}"
    local trunk_if="${VLAN_TRUNK_IF:-}"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would bind WAN_IF (${wan_if:-none}) to ns-wan"
        log_info "[DRY-RUN] Would bind PC_IF (${lan_if:-none}) to ns-pc"
        [[ -n "${stb_if}" ]] && log_info "[DRY-RUN] Would bind STB_IF (${stb_if}) to ns-stb (100M port)"
        [[ -n "${trunk_if}" ]] && log_info "[DRY-RUN] Would configure 802.1Q VLAN trunk on ${trunk_if}"
        return 0
    fi

    # 1. Setup WAN Interface
    [[ -n "${wan_if}" ]] || fatal "WAN_IF not configured in config.env"
    ns_create "${WAN_NS:-ns-wan}"
    unmanage_interface "${wan_if}"
    ip link set "${wan_if}" netns "${WAN_NS:-ns-wan}"
    if [[ -n "${WAN_VLAN_ID:-}" ]]; then
        log_info "Configuring 802.1Q VLAN ${WAN_VLAN_ID} on physical WAN adapter (for tagged WAN)..."
        ip -n "${WAN_NS:-ns-wan}" link set "${wan_if}" name "eth-raw"
        ip -n "${WAN_NS:-ns-wan}" link set "eth-raw" up
        ip -n "${WAN_NS:-ns-wan}" link add link "eth-raw" name "eth0" type vlan id "${WAN_VLAN_ID}"
    else
        ip -n "${WAN_NS:-ns-wan}" link set "${wan_if}" name "eth0"
    fi
    ip -n "${WAN_NS:-ns-wan}" link set "eth0" up
    ip -n "${WAN_NS:-ns-wan}" addr add "${WAN_SERVER_IP:-203.0.113.1}/${WAN_PREFIX:-24}" dev eth0
    ip -n "${WAN_NS:-ns-wan}" route replace "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
    ip -n "${WAN_NS:-ns-wan}" route replace default via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
    ip -n "${WAN_NS:-ns-wan}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true

    local ip_ver="${IP_VERSION:-dual}"
    if [[ "${ip_ver}" != "4" && "${ip_ver}" != "v4" && "${ip_ver}" != "ipv4" ]]; then
        ip -n "${WAN_NS:-ns-wan}" -6 addr add "${WAN_IPV6_CIDR:-2001:db8:10::1/64}" dev eth0 nodad 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" sysctl -q -w net.ipv6.conf.default.forwarding=1 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" sysctl -q -w net.ipv6.conf.eth0.forwarding=1 2>/dev/null || true
    fi
    log_info "Bound physical WAN_IF (${wan_if}, VLAN: ${WAN_VLAN_ID:-untagged}) to ${WAN_NS:-ns-wan} (IP: ${WAN_SERVER_IP:-203.0.113.1}, IPv6: ${WAN_IPV6_CIDR:-2001:db8:10::1/64})"

    # 2. Setup PC Interface (Gigabit LAN port)
    ns_create "${PC_NS:-ns-pc}"
    if [[ -n "${trunk_if}" ]]; then
        # 802.1Q VLAN Trunk Mode
        ip link set "${trunk_if}" up 2>/dev/null || true
        local pc_vlan="${trunk_if}.${VLAN_ID_PC:-10}"
        ip link add link "${trunk_if}" name "${pc_vlan}" type vlan id "${VLAN_ID_PC:-10}"
        ip link set "${pc_vlan}" netns "${PC_NS:-ns-pc}"
        ip -n "${PC_NS:-ns-pc}" link set "${pc_vlan}" name "eth0"
    else
        [[ -n "${lan_if}" ]] || fatal "LAN_IF / PC_IF not configured in config.env"
        unmanage_interface "${lan_if}"
        ip link set "${lan_if}" netns "${PC_NS:-ns-pc}"
        ip -n "${PC_NS:-ns-pc}" link set "${lan_if}" name "eth0"
    fi
    ip -n "${PC_NS:-ns-pc}" link set "eth0" up
    if (( ${LAN_DHCP_CLIENT:-1} == 1 )); then
        log_info "Bound physical PC interface to ${PC_NS:-ns-pc} (Dynamic DHCP Mode: leases from DUT)..."
    else
        ip -n "${PC_NS:-ns-pc}" addr add "${PC_IP:-192.168.1.10}/${LAN_PREFIX:-24}" dev eth0
        ip -n "${PC_NS:-ns-pc}" route replace default via "${DUT_LAN_IP:-192.168.1.1}" dev eth0
        log_info "Bound physical PC interface to ${PC_NS:-ns-pc} (Static IP: ${PC_IP:-192.168.1.10})"
    fi

    # 3. Setup IPTV STB Interface (Dedicated 100M port on DUT)
    if [[ -n "${stb_if}" || -n "${trunk_if}" ]]; then
        ns_create "${STB_NS:-ns-stb}"
        if [[ -n "${trunk_if}" ]]; then
            local stb_vlan="${trunk_if}.${VLAN_ID_STB:-20}"
            ip link add link "${trunk_if}" name "${stb_vlan}" type vlan id "${VLAN_ID_STB:-20}"
            ip link set "${stb_vlan}" netns "${STB_NS:-ns-stb}"
            ip -n "${STB_NS:-ns-stb}" link set "${stb_vlan}" name "eth0"
        else
            unmanage_interface "${stb_if}"
            ip link set "${stb_if}" netns "${STB_NS:-ns-stb}"
            ip -n "${STB_NS:-ns-stb}" link set "${stb_if}" name "eth0"
        fi
        ip -n "${STB_NS:-ns-stb}" link set "eth0" up
        if (( ${LAN_DHCP_CLIENT:-1} == 1 )); then
            log_info "Bound physical STB interface to ${STB_NS:-ns-stb} (Dynamic DHCP Mode: leases from DUT)..."
        else
            ip -n "${STB_NS:-ns-stb}" addr add "${STB_IP:-192.168.1.20}/${LAN_PREFIX:-24}" dev eth0
            ip -n "${STB_NS:-ns-stb}" route replace default via "${DUT_LAN_IP:-192.168.1.1}" dev eth0
            log_info "Bound physical STB interface (${stb_if:-${trunk_if}.${VLAN_ID_STB:-20}}) to ${STB_NS:-ns-stb} (Static IP: ${STB_IP:-192.168.1.20})"
        fi
        # Force or request 100BASE-TX full-duplex on physical adapter if supported
        ip netns exec "${STB_NS:-ns-stb}" ethtool -s eth0 speed 100 duplex full autoneg off 2>/dev/null || true
        log_info "Bound physical STB interface (${stb_if:-${trunk_if}.${VLAN_ID_STB:-20}}) to ${STB_NS:-ns-stb} (IP: ${STB_IP:-192.168.1.20})"
    else
        log_warn "STB_IF not configured. Rate mismatch tests (TC-RM) will require STB_IF or virtual mode."
    fi

    # 4. Optional dedicated physical Wi-Fi / Phone interfaces
    local wlan_map=(
        "${WLAN2G_NS:-ns-wlan2g}:${WLAN2G_IF:-}:${WLAN2G_IP:-192.168.1.31}"
        "${WLAN5G_NS:-ns-wlan5g}:${WLAN5G_IF:-}:${WLAN5G_IP:-192.168.1.32}"
        "${WLAN6G_NS:-ns-wlan6g}:${WLAN6G_IF:-}:${WLAN6G_IP:-192.168.1.33}"
        "${PHONE1_NS:-ns-phone1}:${PHONE1_IF:-}:${PHONE1_IP:-192.168.1.41}"
        "${PHONE2_NS:-ns-phone2}:${PHONE2_IF:-}:${PHONE2_IP:-192.168.1.42}"
    )

    local item w_ns w_if w_ip
    for item in "${wlan_map[@]}"; do
        w_ns="${item%%:*}"
        w_if="${item#*:}"
        w_ip="${w_if#*:}"
        w_if="${w_if%%:*}"

        if [[ -n "${w_if}" ]]; then
            ns_create "${w_ns}"
            unmanage_interface "${w_if}"
            ip link set "${w_if}" netns "${w_ns}"
            ip -n "${w_ns}" link set "${w_if}" name "eth0"
            ip -n "${w_ns}" link set "eth0" up
            ip -n "${w_ns}" addr add "${w_ip}/${LAN_PREFIX:-24}" dev eth0
            ip -n "${w_ns}" route replace default via "${DUT_LAN_IP:-192.168.1.1}" dev eth0
            log_info "Bound physical wireless/phone adapter (${w_if}) to ${w_ns} (IP: ${w_ip})"
        fi
    done

    # 5. Tune network buffer limits across all active namespaces
    local active_ns
    for active_ns in "${WAN_NS:-ns-wan}" "${PC_NS:-ns-pc}" "${STB_NS:-ns-stb}"; do
        if ns_exists "${active_ns}"; then
            ip netns exec "${active_ns}" sysctl -q -w net.core.rmem_max=16777216 2>/dev/null || true
            ip netns exec "${active_ns}" sysctl -q -w net.core.wmem_max=16777216 2>/dev/null || true
            ip netns exec "${active_ns}" sysctl -q -w net.core.netdev_max_backlog=10000 2>/dev/null || true
        fi
    done

    # 6. Start Upstream WAN DHCP server to lease IP to DUT WAN port
    if (( ${WAN_DHCP_ENABLE:-1} == 1 )) && [[ -x "${SCRIPT_DIR}/wan_server.sh" ]]; then
        log_info "Activating upstream WAN DHCP server via wan_server.sh..."
        "${SCRIPT_DIR}/wan_server.sh" start "${WAN_DHCP_BACKEND:-auto}" || true
    fi

    # 7. Start LAN client DHCP leasing from DUT if requested
    if (( ${LAN_DHCP_CLIENT:-1} == 1 )) && [[ -x "${SCRIPT_DIR}/client_dhcp.sh" ]]; then
        log_info "Activating LAN client dynamic DHCP leasing from DUT via client_dhcp.sh..."
        "${SCRIPT_DIR}/client_dhcp.sh" renew all || true
    fi

    log_success "Physical Multi-Port topology successfully established."
}

# Defensive: Atomic state file persistence
save_topology_state() {
    local state_file="${STATE_DIR}/topology_state.env"
    local temp_state="${STATE_DIR}/topology_state.env.tmp.$$"
    mkdir -p "${STATE_DIR}"

    cat > "${temp_state}" <<EOF
TOPOLOGY_ACTIVE="1"
TOPOLOGY_MODE="${TOPOLOGY_MODE}"
WAN_NS="${WAN_NS:-ns-wan}"
DUT_NS="${DUT_NS:-ns-dut}"
PC_NS="${PC_NS:-ns-pc}"
STB_NS="${STB_NS:-ns-stb}"
WLAN2G_NS="${WLAN2G_NS:-ns-wlan2g}"
WLAN5G_NS="${WLAN5G_NS:-ns-wlan5g}"
WLAN6G_NS="${WLAN6G_NS:-ns-wlan6g}"
PHONE1_NS="${PHONE1_NS:-ns-phone1}"
PHONE2_NS="${PHONE2_NS:-ns-phone2}"
CREATED_AT="$(date -Iseconds)"
EOF
    chmod 0666 "${temp_state}" 2>/dev/null || true
    mv -f "${temp_state}" "${state_file}"
    log_info "Topology state saved atomically to ${state_file}"
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config "${LAB_DIR}/config.env"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --virtual|-v|--no-dut)
                TOPOLOGY_MODE="virtual"
                shift
                ;;
            --single|-s)
                TOPOLOGY_MODE="physical"
                shift
                ;;
            --lan-dhcp|--dhcp-client)
                LAN_DHCP_CLIENT=1
                shift
                ;;
            --no-lan-dhcp|--static-lan)
                LAN_DHCP_CLIENT=0
                shift
                ;;
            --wan-dhcp)
                WAN_DHCP_ENABLE=1
                shift
                ;;
            --no-wan-dhcp)
                WAN_DHCP_ENABLE=0
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if (( DRY_RUN == 0 )); then
        require_root
        require_command ip
        require_command tc
    fi

    ensure_runtime_dirs

    # Arm automatic rollback
    trap 'rollback_setup $? ${LINENO}' ERR
    SETUP_ACTIVE=1

    if [[ "${TOPOLOGY_MODE}" == "virtual" ]]; then
        setup_virtual_topology
    else
        setup_physical_topology
    fi

    if (( DRY_RUN == 0 )); then
        save_topology_state
    fi

    SETUP_ACTIVE=0
    trap - ERR

    log_success "Setup finished successfully. Ready for test scenarios."
}

main "$@"
