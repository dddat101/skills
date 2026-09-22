#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - CLEANUP SCRIPT BOILERPLATE
# Idempotently tears down netns, veths, bridges, daemons,
# and restores physical interfaces to UP state with DHCP.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Gracefully stops daemons, tears down network namespaces, bridges,
  and virtual interfaces, and restores physical network adapters.
  Supports selective, non-destructive cleaning of logs and captures.

Usage:
  sudo ./scripts/cleanup.sh [options]
  ./scripts/cleanup.sh [command]

Options:
  -r, --restore, --dhcp    Restore physical interfaces (WAN_IF, LAN_IF) to UP, re-enable NetworkManager,
                           and trigger DHCP [Default]
  -d, --down, --no-restore Keep physical interfaces DOWN and flushed (isolated test mode)
  --logs                   Purge all test logs in logs/
  --captures               Purge all PCAP captures in captures/
  -a, --all                Teardown topology and purge state, logs, and captures
  -h, --help               Show this help message

Subcommands (Non-destructive to running topology):
  logs                     Purge logs/ without tearing down lab
  captures                 Purge captures/ without tearing down lab
  data                     Purge both logs/ and captures/ without tearing down lab

Examples:
  sudo ./scripts/cleanup.sh
  sudo ./scripts/cleanup.sh --all
  sudo ./scripts/cleanup.sh --down
  ./scripts/cleanup.sh logs
  ./scripts/cleanup.sh data

Suggested Next Steps:
  - Verify clean state:    ./scripts/show_state.sh
  - Deploy virtual lab:    sudo ./scripts/setup.sh --virtual
  - Deploy physical lab:   sudo ./scripts/setup.sh --single
USAGE
}

main() {
    local arg
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config

    # Non-destructive subcommands (Run without requiring root)
    case "${1:-}" in
        logs)     clean_logs; exit 0 ;;
        captures) clean_captures; exit 0 ;;
        data)     clean_logs; clean_captures; exit 0 ;;
    esac

    require_root
    require_command ip

    local restore="${RESTORE_INTERFACES_ON_CLEANUP:-1}"
    local clean_logs_flag=0
    local clean_captures_flag=0

    while (( $# > 0 )); do
        case "$1" in
            -r|--restore|--dhcp)    restore=1; shift ;;
            -d|--down|--no-restore) restore=0; shift ;;
            --logs)                 clean_logs_flag=1; shift ;;
            --captures)             clean_captures_flag=1; shift ;;
            -a|--all)               clean_logs_flag=1; clean_captures_flag=1; shift ;;
            *)                      usage; exit 2 ;;
        esac
    done

    print_header "CLEANING UP TEST LAB ENVIRONMENT"
    log_info "Initiating cleanup (restore_interfaces=${restore})..."

    # 1. Stop packet captures and client daemons
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi
    if [[ -x "${SCRIPT_DIR}/client_dhcp.sh" ]]; then
        "${SCRIPT_DIR}/client_dhcp.sh" release 2>/dev/null || true
    fi

    # 2. Stop daemons recorded in PID files
    local pidfile
    for pidfile in "${STATE_DIR}"/*.pid; do
        [[ -f "${pidfile}" ]] && stop_pidfile "${pidfile}"
    done

    # 3. Terminate background processes inside namespaces
    local ns
    for ns in "${WAN_NS:-ns-wan}" "${LAN_NS:-ns-lan}" "${DUT_NS:-ns-dut}"; do
        if ns_exists "${ns}"; then
            ip netns exec "${ns}" pkill -TERM tcpdump 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM udhcpc 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM dhclient 2>/dev/null || true
        fi
    done

    # 4. Delete virtual interfaces (host-side veth ends)
    local veth
    for veth in veth-wansrv veth-lancli veth-dutwan veth-dutlan; do
        if ip link show dev "${veth}" >/dev/null 2>&1; then
            ip link del dev "${veth}" 2>/dev/null || true
        fi
    done

    # 5. Delete network namespaces
    for ns in "${WAN_NS:-ns-wan}" "${LAN_NS:-ns-lan}" "${DUT_NS:-ns-dut}"; do
        if ns_exists "${ns}"; then
            ip netns del "${ns}" 2>/dev/null || true
        fi
    done

    # 6. Delete test bridges
    local br
    for br in "${WAN_BRIDGE:-br-test-wan}" "${LAN_BRIDGE:-br-test-lan}"; do
        if bridge_exists "${br}"; then
            ip link set dev "${br}" down 2>/dev/null || true
            ip link del dev "${br}" 2>/dev/null || true
        fi
    done

    # 7. Restore physical interfaces to UP + DHCP (or keep DOWN if requested)
    local ifaces=()
    local ifname
    for ifname in "${WAN_IF:-}" "${LAN_IF:-}" "${TEST_IF:-}"; do
        if [[ -n "${ifname}" ]] && iface_exists_root "${ifname}"; then
            if [[ ! " ${ifaces[*]:-} " =~ [[:space:]]${ifname}[[:space:]] ]]; then
                ifaces+=("${ifname}")
            fi
        fi
    done

    for ifname in "${ifaces[@]:-}"; do
        if (( restore == 1 )); then
            restore_physical_interface "${ifname}"
        else
            tear_down_physical_interface "${ifname}"
        fi
    done

    # 8. Clean runtime state files
    rm -f "${STATE_DIR}/topology_state.env" "${STATE_DIR}/last_capture.env" 2>/dev/null || true
    rm -f "${STATE_DIR}"/*.pid "${STATE_DIR}"/*.leases "${STATE_DIR}"/*.conf "${STATE_DIR}"/*.state 2>/dev/null || true

    if (( clean_logs_flag == 1 )); then clean_logs; fi
    if (( clean_captures_flag == 1 )); then clean_captures; fi

    log_success "Cleanup completed successfully!"
    printf '\nSuggested next steps:\n'
    printf '  - Check lab state:     ./scripts/show_state.sh\n'
    printf '  - Deploy virtual lab:  sudo ./scripts/setup.sh --virtual\n'
}

main "$@"
