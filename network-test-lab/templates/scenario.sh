#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - AUTOMATED SCENARIO RUNNER BOILERPLATE
# Modular execution, deterministic socket waits & dual-layer verification handoff
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  Carrier Network Test Lab - Scenario Runner
==================================================================

Description:
  Automates multi-phase test scenarios, triggers packet capture,
  injects protocol traffic, and hands off to automated verification.

Usage:
  sudo ./scripts/scenario.sh [SCENARIO]

Supported Scenarios:
  all             (Default) Run complete multi-phase verification suite
  discovery       Phase 1: DHCP / Network Discovery Handshake
  traffic         Phase 2: Data Plane Forwarding & Bandwidth Test
  security        Phase 3: Access Control & Ingress Filtering Isolation
  -h, --help      Show this help message and exit

Examples:
  sudo ./scripts/scenario.sh discovery
  sudo ./scripts/scenario.sh all

Suggested Next Steps:
  1. Inspect verification report: ./scripts/verify_compliance.sh
  2. Inspect capture state:       ./scripts/show_state.sh
  3. Teardown when finished:      sudo ./scripts/cleanup.sh
==================================================================
USAGE
}

run_phase_discovery() {
    log_step "[PHASE 1] Network Discovery & Addressing"
    log_info "Initiating client discovery in ${LAN_NS:-ns-lan}..."
    if [[ -x "${SCRIPT_DIR}/client_dhcp.sh" ]]; then
        "${SCRIPT_DIR}/client_dhcp.sh" request "${LAN_NS:-ns-lan}" || true
    else
        log_info "Simulating discovery handshake..."
        exec_in_ns "${LAN_NS:-ns-lan}" ping -c 2 "${DUT_LAN_IP:-192.168.1.1}" || true
    fi
}

run_phase_traffic() {
    log_step "[PHASE 2] Data Plane Forwarding Test"
    log_info "Testing connectivity from LAN client to WAN server..."
    if is_ip_reachable "${WAN_SERVER_IP:-10.10.0.10}" 2 "${LAN_NS:-ns-lan}"; then
        log_success "WAN reachability confirmed through DUT!"
    else
        log_warn "Ping to WAN server failed or was dropped."
    fi
}

run_phase_security() {
    log_step "[PHASE 3] Ingress Isolation & Security Assertion"
    log_info "Verifying that unauthorized traffic is rejected..."
    # Inject test traffic or probe closed ports
    exec_in_ns "${WAN_NS:-ns-wan}" ping -c 1 -W 1 "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true
}

main() {
    local scenario="${1:-all}"
    if [[ "${scenario}" == "-h" || "${scenario}" == "--help" ]]; then
        usage
        exit 0
    fi

    require_root
    load_config
    ensure_runtime_dirs

    print_header "STARTING TEST SCENARIO: [${scenario^^}]"

    # Clean audit logs for fresh run
    rm -f "${LOG_DIR}"/*audit*.jsonl 2>/dev/null || true

    # Phase 0: Start Background Capture
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        bash "${SCRIPT_DIR}/capture.sh" start
        trap 'bash "${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true; if [[ -x "${SCRIPT_DIR}/stop_servers.sh" ]]; then bash "${SCRIPT_DIR}/stop_servers.sh" >/dev/null 2>&1 || true; fi' EXIT INT TERM
    fi

    case "${scenario}" in
        all)
            run_phase_discovery
            run_phase_traffic
            run_phase_security
            ;;
        discovery) run_phase_discovery ;;
        traffic)   run_phase_traffic ;;
        security)  run_phase_security ;;
        *)         log_error "Unknown scenario: ${scenario}"; usage; exit 1 ;;
    esac

    # Stop capture cleanly
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        trap - EXIT INT TERM
        bash "${SCRIPT_DIR}/capture.sh" stop
    fi

    log_info "Scenario completed. Proceeding to compliance verification..."
    if [[ -x "${SCRIPT_DIR}/verify_compliance.sh" ]]; then
        bash "${SCRIPT_DIR}/verify_compliance.sh"
    fi
}

main "$@"
