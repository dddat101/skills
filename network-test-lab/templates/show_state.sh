#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - RUNTIME STATE OBSERVER
# Non-root graceful degradation, stale PID detection & topology inspection
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Inspects and reports current runtime state of the network test lab,
  including active namespaces, bridges, interface addresses, daemons,
  and captured PCAP evidence.

Usage:
  ./scripts/show_state.sh [options]
  ./scripts/show_state.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Suggested Next Steps:
  - Run test scenarios:    sudo ./scripts/scenario.sh all
  - Verify compliance:     ./scripts/verify_compliance.sh
  - Teardown when done:    sudo ./scripts/cleanup.sh
USAGE
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    print_header "NETWORK TEST LAB RUNTIME STATE"

    # 1. Topology State
    print_section "TOPOLOGY METADATA"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        cat "${STATE_DIR}/topology_state.env"
    else
        printf 'No active topology state found (run sudo ./scripts/setup.sh).\n'
    fi

    # 2. Linux Bridges
    print_section "BRIDGES & PORTS"
    local br
    for br in "${WAN_BRIDGE:-br-test-wan}" "${LAN_BRIDGE:-br-test-lan}"; do
        if bridge_exists "${br}"; then
            printf 'Bridge: %s (State: UP)\n' "${br}"
            ip link show master "${br}" 2>/dev/null | grep -E '^[0-9]+:' | awk '{print "  - Member: "$2}' | tr -d ':' || true
        else
            printf 'Bridge: %s (NOT FOUND)\n' "${br}"
        fi
    done

    # 3. Namespaces & Interfaces
    print_section "NETWORK NAMESPACES & INTERFACES"
    local all_ns=(
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

    if is_root; then
        local ns
        for ns in "${all_ns[@]}"; do
            if ns_exists "${ns}"; then
                printf 'Namespace: \e[1;36m%s\e[0m\n' "${ns}"
                ip netns exec "${ns}" ip -br -4 addr show 2>/dev/null | awk '{printf "  [IPv4] %-12s %s\n", $1, $3}' || true
                ip netns exec "${ns}" ip -br -6 addr show 2>/dev/null | awk '{printf "  [IPv6] %-12s %s\n", $1, $3}' || true
                ip netns exec "${ns}" ip -4 route show 2>/dev/null | awk '{printf "    v4 route: %s\n", $0}' || true
                ip netns exec "${ns}" ip -6 route show default 2>/dev/null | awk '{printf "    v6 route: %s\n", $0}' || true
                if [[ "${ns}" == "${DUT_NS:-ns-dut}" ]]; then
                    printf '  [QoS/Traffic Control on STB Link]\n'
                    ip netns exec "${ns}" tc qdisc show dev veth-dut-stb 2>/dev/null | awk '{printf "    tc: %s\n", $0}' || true
                fi
            fi
        done
    else
        printf 'Note: Run with sudo to inspect internal netns IPs, routing, and traffic control rules.\n'
        ip netns list 2>/dev/null | awk '{printf "Namespace present: %s\n", $1}' || true
    fi

    # 4. Supervised Daemons & Stale PID Detection
    print_section "SUPERVISED DAEMONS & SERVICES"
    local pid_found=0
    local pid_file
    for pid_file in "${STATE_DIR}"/*.pid; do
        if [[ -f "${pid_file}" ]]; then
            pid_found=1
            local name pid
            name="$(basename "${pid_file}" .pid)"
            pid="$(cat "${pid_file}" 2>/dev/null || true)"
            if is_pidfile_running "${pid_file}"; then
                printf '  %-24s -> \e[1;32mRUNNING\e[0m (PID: %s)\n' "${name}" "${pid}"
            else
                printf '  %-24s -> \e[1;31mSTALE PID FILE\e[0m (Process dead)\n' "${name}"
            fi
        fi
    done
    if (( pid_found == 0 )); then
        printf 'No active daemon PID files registered.\n'
    fi

    # 5. Packet Captures
    print_section "PACKET CAPTURES"
    if [[ -d "${CAPTURE_DIR}" ]]; then
        local pcap_count=0
        while IFS= read -r pcap_path; do
            if [[ -f "${pcap_path}" ]]; then
                pcap_count=$((pcap_count + 1))
                local size
                size="$(du -h "${pcap_path}" | cut -f1)"
                printf '  [%s] %s\n' "${size}" "$(basename "${pcap_path}")"
            fi
        done < <(find "${CAPTURE_DIR}" -maxdepth 1 -name '*.pcap*' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' | head -n 5)
        if (( pcap_count == 0 )); then
            printf 'No PCAP capture files found in %s.\n' "${CAPTURE_DIR}"
        fi
    fi
    printf '==================================================================\n'
}

main "$@"
