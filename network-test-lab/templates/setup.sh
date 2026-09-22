#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - TOPOLOGY SETUP BOILERPLATE
# Supports Virtual Simulation, Single-PC Dual-NIC, and Distributed 2-PC Topologies
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0

usage() {
    cat <<'EOF'
==================================================================
  Carrier Network Test Lab - Topology Setup
==================================================================

Description:
  Initializes network topology, Linux bridges, network namespaces,
  and interface bindings required for automated test scenarios.

Usage:
  sudo ./scripts/setup.sh [OPTIONS]

Topology Options:
  --virtual, -v, --no-dut
      Pure software simulation using isolated Linux network namespaces
      (ns-wan, ns-dut, ns-lan) and veth pairs. Zero physical hardware required.

  --single, -s
      Single-PC Dual-NIC physical topology. Connects host WAN NIC ($WAN_IF)
      to DUT WAN, and host LAN NIC ($LAN_IF) to DUT LAN.

  --wan
      Distributed 2-PC topology (Node 1): Sets up host as WAN Gateway/Server ($TEST_IF).

  --lan
      Distributed 2-PC topology (Node 2): Sets up host as LAN Client endpoint ($TEST_IF).

  -h, --help
      Show this help message and exit.

Examples:
  sudo ./scripts/setup.sh --virtual
  sudo ./scripts/setup.sh --single

Suggested Next Steps:
  1. Inspect runtime state:       ./scripts/show_state.sh
  2. Start test servers:          sudo ./scripts/start_servers.sh
  3. Execute test scenarios:      sudo ./scripts/scenario.sh all
  4. Verify compliance & PCAP:    ./scripts/verify_compliance.sh
  5. Teardown when finished:      sudo ./scripts/cleanup.sh
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

setup_virtual_dut() {
    local ns_dut="${DUT_NS:-ns-dut}"
    log_info "Creating simulated DUT router ${ns_dut} for offline testing..."
    ns_create "${ns_dut}"

    # Veth to WAN bridge
    create_veth_to_ns "${ns_dut}" "veth-dutwan" "eth-wan" "${WAN_BRIDGE}" "${DUT_WAN_IP:-10.10.0.1}/${WAN_PREFIX:-24}" ""

    # Veth to LAN bridge
    create_veth_to_ns "${ns_dut}" "veth-dutlan" "eth-lan" "${LAN_BRIDGE}" "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" ""

    # Enable routing and NAT inside simulated DUT
    ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -F 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -t nat -F 2>/dev/null || true
    ip netns exec "${ns_dut}" iptables -t nat -A POSTROUTING -o eth-wan -j MASQUERADE 2>/dev/null || true
    ip -n "${ns_dut}" route replace default via "${WAN_SERVER_IP:-10.10.0.10}" dev eth-wan 2>/dev/null || true
}

main() {
    # Allow non-root users to view help
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    require_root
    require_command ip

    load_config

    local mode="${TOPOLOGY_MODE:-virtual}"
    local role="${LAB_ROLE:-single}"

    while (( $# > 0 )); do
        case "$1" in
            --virtual|-v|--no-dut) mode="virtual"; shift ;;
            --single|-s)          mode="physical"; role="single"; shift ;;
            --wan)                mode="physical"; role="wan"; shift ;;
            --lan)                mode="physical"; role="lan"; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # 1. Activate auto-rollback trap
    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    print_header "INITIALIZING TOPOLOGY: [${mode^^}] [ROLE: ${role^^}]"
    ensure_runtime_dirs

    # 2. Build topology according to mode & role
    if [[ "${mode}" == "virtual" ]]; then
        bridge_create "${WAN_BRIDGE}"
        bridge_create "${LAN_BRIDGE}"
        create_veth_to_ns "${WAN_NS:-ns-wan}" "veth-wansrv" "eth-wan" "${WAN_BRIDGE}" "${WAN_SERVER_IP:-10.10.0.10}/${WAN_PREFIX:-24}" "${DUT_WAN_IP:-10.10.0.1}"
        create_veth_to_ns "${LAN_NS:-ns-lan}" "veth-lancli" "eth-lan" "${LAN_BRIDGE}" "${LAN_CLIENT_IP:-192.168.1.100}/${LAN_PREFIX:-24}" "${DUT_LAN_IP:-192.168.1.1}"
        setup_virtual_dut
    elif [[ "${mode}" == "physical" ]]; then
        if [[ "${role}" == "single" ]]; then
            assert_safe_test_if "${WAN_IF}"
            assert_safe_test_if "${LAN_IF}"
            bridge_create "${WAN_BRIDGE}"; attach_physical_to_bridge "${WAN_IF}" "${WAN_BRIDGE}"
            bridge_create "${LAN_BRIDGE}"; attach_physical_to_bridge "${LAN_IF}" "${LAN_BRIDGE}"
            create_veth_to_ns "${WAN_NS:-ns-wan}" "veth-wansrv" "eth-wan" "${WAN_BRIDGE}" "${WAN_SERVER_IP:-10.10.0.10}/${WAN_PREFIX:-24}" "${DUT_WAN_IP:-10.10.0.1}"
            create_veth_to_ns "${LAN_NS:-ns-lan}" "veth-lancli" "eth-lan" "${LAN_BRIDGE}" "${LAN_CLIENT_IP:-192.168.1.100}/${LAN_PREFIX:-24}" "${DUT_LAN_IP:-192.168.1.1}"
        elif [[ "${role}" == "wan" ]]; then
            assert_safe_test_if "${TEST_IF}"
            bridge_create "${WAN_BRIDGE}"; attach_physical_to_bridge "${TEST_IF}" "${WAN_BRIDGE}"
            create_veth_to_ns "${WAN_NS:-ns-wan}" "veth-wansrv" "eth-wan" "${WAN_BRIDGE}" "${WAN_SERVER_IP:-10.10.0.10}/${WAN_PREFIX:-24}" "${DUT_WAN_IP:-10.10.0.1}"
        elif [[ "${role}" == "lan" ]]; then
            assert_safe_test_if "${TEST_IF}"
            bridge_create "${LAN_BRIDGE}"; attach_physical_to_bridge "${TEST_IF}" "${LAN_BRIDGE}"
            create_veth_to_ns "${LAN_NS:-ns-lan}" "veth-lancli" "eth-lan" "${LAN_BRIDGE}" "${LAN_CLIENT_IP:-192.168.1.100}/${LAN_PREFIX:-24}" "${DUT_LAN_IP:-192.168.1.1}"
        fi
    fi

    # 3. Save runtime topology state
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

    # 4. Disable rollback on success
    SETUP_ACTIVE=0
    trap - ERR
    log_success "Topology setup successfully completed!"
    if [[ -x "${SCRIPT_DIR}/show_state.sh" ]]; then
        bash "${SCRIPT_DIR}/show_state.sh" || true
    fi

    printf '\n'
    print_header "SUGGESTED NEXT STEPS"
    cat <<'NEXT_STEP'
  1. Start mock WAN servers:      sudo ./scripts/start_servers.sh
  2. Run automated test suite:    sudo ./scripts/scenario.sh all
  3. Verify compliance & PCAP:    ./scripts/verify_compliance.sh
  4. Collect DUT snapshot (SSH):  ./scripts/dut_collector.sh
  5. Teardown when finished:      sudo ./scripts/cleanup.sh
==================================================================
NEXT_STEP
}

main "$@"
