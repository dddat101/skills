#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PRE-FLIGHT SYSTEM DIAGNOSTICS
# Non-destructive environment, toolchain, and host safety assertion
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
  Performs pre-flight checks on host environment, required CLI binaries,
  interface safety (preventing default route hijacking), and test readiness.

Usage:
  ./scripts/diagnose.sh [options]
  ./scripts/diagnose.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Suggested Next Steps:
  - Deploy topology:  sudo ./scripts/setup.sh --virtual
  - Inspect state:    ./scripts/show_state.sh
USAGE
}

check_item() {
    local label="$1" status="$2" note="${3:-}"
    if [[ "${status}" == "PASS" ]]; then
        printf '  \e[1;32m[PASS]\e[0m %-30s %s\n' "${label}" "${note}"
    elif [[ "${status}" == "WARN" ]]; then
        printf '  \e[1;33m[WARN]\e[0m %-30s %s\n' "${label}" "${note}"
    else
        printf '  \e[1;31m[FAIL]\e[0m %-30s %s\n' "${label}" "${note}"
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    print_header "PRE-FLIGHT ENVIRONMENT DIAGNOSTICS"

    # 1. Essential Tools
    print_section "CORE TOOLCHAIN AVAILABILITY"
    local tool
    for tool in ip tcpdump tshark python3 openssl curl; do
        if check_command "${tool}"; then
            check_item "Binary: ${tool}" "PASS" "$(command -v "${tool}")"
        else
            check_item "Binary: ${tool}" "WARN" "Not found in PATH"
        fi
    done

    # 2. WAN DHCP & Dual-Stack Services
    print_section "WAN DHCP & DUAL-STACK DAEMONS"
    local srv
    for srv in kea-dhcp4 kea-dhcp6 radvd dnsmasq; do
        if check_command "${srv}"; then
            check_item "Server: ${srv}" "PASS" "$(command -v "${srv}")"
        else
            check_item "Server: ${srv}" "WARN" "Not installed (Fallback logic applies)"
        fi
    done

    # 3. Host Network Safety Assertions
    print_section "HOST NETWORK SAFETY"
    local default_if
    default_if="$((ip route show default 2>/dev/null || true) | awk '/dev/ {print $5}' | head -n1 || echo "")"
    if [[ -n "${default_if}" ]]; then
        check_item "Host Default Route" "PASS" "Interface: ${default_if}"
    else
        check_item "Host Default Route" "WARN" "No default route detected on host"
    fi

    local iface
    for iface in "${WAN_IF:-}" "${LAN_IF:-}"; do
        if [[ -n "${iface}" ]]; then
            if iface_exists_root "${iface}"; then
                if [[ "${iface}" == "${default_if}" ]]; then
                    check_item "Safety check: ${iface}" "FAIL" "DANGER: Test NIC carries host default route!"
                else
                    check_item "Safety check: ${iface}" "PASS" "Isolated from host default route"
                fi
            else
                check_item "Interface presence: ${iface}" "WARN" "Physical NIC not currently connected"
            fi
        fi
    done

    # 4. Kernel Modules & Features
    print_section "KERNEL CAPABILITIES"
    if [[ -d /sys/class/net ]]; then
        check_item "Linux Network Stack" "PASS" "sysfs net available"
    fi
    if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then
        local fwd
        fwd="$(cat /proc/sys/net/ipv4/ip_forward)"
        check_item "Host IPv4 Forwarding" "PASS" "State: ${fwd}"
    fi
    if [[ -d /proc/sys/net/ipv6 ]]; then
        check_item "Host IPv6 Stack" "PASS" "IPv6 enabled in kernel"
    else
        check_item "Host IPv6 Stack" "WARN" "IPv6 stack disabled or unavailable"
    fi

    # 4. Runtime Directories
    print_section "RUNTIME STORAGE DIRECTORIES"
    local dir
    for dir in "${CAPTURE_DIR}" "${LOG_DIR}" "${STATE_DIR}"; do
        if [[ -d "${dir}" ]]; then
            check_item "Directory: $(basename "${dir}")" "PASS" "${dir}"
        else
            check_item "Directory: $(basename "${dir}")" "WARN" "Will be created on setup"
        fi
    done
    printf '==================================================================\n'
}

main "$@"
