#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PACKET CAPTURE MANAGER
# Prioritizes tcpdump (-U -s 0) to avoid dumpcap privilege drop issues
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Manages background packet capture (tcpdump / tshark) on LAN or WAN interfaces.
  Captures protocol signaling and test traffic to PCAP files for automated verification.

Usage:
  sudo ./scripts/capture.sh start [target_ns] [target_if] [bpf_filter]
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh status
  ./scripts/capture.sh clean
  ./scripts/capture.sh -h | --help

Commands:
  start [ns] [if] [filter]  Start background packet capture
  stop                      Stop active background packet capture
  status                    Display capture status, active PID, and output PCAP file details
  clean                     Stop active capture and purge all capture files in captures/
  -h, --help                Show this help message

Examples:
  sudo ./scripts/capture.sh start
  sudo ./scripts/capture.sh start ns-lan eth-lan "(udp port 67 or udp port 68) or arp"
  sudo ./scripts/capture.sh status
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh clean

Suggested Next Steps:
  - Run automated analysis: ./scripts/verify_compliance.sh
  - Inspect running status: ./scripts/capture.sh status
USAGE
}

start_capture() {
    require_root
    stop_capture

    local target_ns="${1:-${LAN_NS:-ns-lan}}"
    local target_if="${2:-eth-lan}"
    local bpf_filter="${3:-${CAPTURE_FILTER:-}}"

    local timestamp ext cap_tool pcap_file pid_file log_file
    timestamp="$(date +%Y%m%d_%H%M%S)"
    pid_file="${STATE_DIR}/capture.pid"
    log_file="${LOG_DIR}/capture_${timestamp}.log"

    # Production rule: Always prefer tcpdump over tshark for capturing to prevent dumpcap privilege drop
    if command -v "${TCPDUMP_BIN:-tcpdump}" >/dev/null 2>&1; then
        cap_tool="tcpdump"; ext="pcap"
    elif command -v "${TSHARK_BIN:-tshark}" >/dev/null 2>&1; then
        cap_tool="tshark"; ext="pcapng"
    else
        die "Neither tcpdump nor tshark is installed."
    fi

    pcap_file="${CAPTURE_DIR}/capture_${timestamp}.${ext}"
    ensure_runtime_dirs

    local cap_cmd=()
    if [[ "${cap_tool}" == "tcpdump" ]]; then
        cap_cmd=("tcpdump" "-ni" "${target_if}" "-s" "0" "-U" "-w" "${pcap_file}")
        if [[ -n "${bpf_filter}" ]]; then
            cap_cmd+=(${bpf_filter})
        fi
    else
        cap_cmd=("tshark" "-i" "${target_if}" "-l" "-w" "${pcap_file}")
        if [[ -n "${bpf_filter}" ]]; then
            cap_cmd+=("-f" "${bpf_filter}")
        fi
    fi

    local exec_prefix=()
    if ns_exists "${target_ns}"; then
        exec_prefix=("ip" "netns" "exec" "${target_ns}")
    fi

    log_info "Starting packet capture on ${target_ns}:${target_if} (${cap_tool})..."
    "${exec_prefix[@]}" nohup "${cap_cmd[@]}" > "${log_file}" 2>&1 &
    local cap_pid=$!
    echo "${cap_pid}" > "${pid_file}"
    chmod 0666 "${pid_file}" "${log_file}" 2>/dev/null || true

    cat >"${STATE_DIR}/last_capture.env" <<EOF
LAST_PCAP='${pcap_file}'
CAPTURE_TIMESTAMP='$(date -Iseconds)'
CAPTURE_TOOL='${cap_tool}'
CAPTURE_NS='${target_ns}'
CAPTURE_IF='${target_if}'
EOF
    echo "${pcap_file}" > "${STATE_DIR}/latest_capture.txt"

    sleep 0.5
    if ! is_pidfile_running "${pid_file}"; then
        log_error "Capture failed to start. Log output:"
        tail -n 20 "${log_file}" >&2 || true
        die "Failed to start capture process."
    fi

    log_success "Capture active: ${pcap_file} (PID: ${cap_pid})"
}

stop_capture() {
    require_root
    if [[ -f "${STATE_DIR}/capture.pid" ]]; then
        stop_pidfile "${STATE_DIR}/capture.pid" "Packet Capture"
    fi
}

show_status() {
    print_header "CAPTURE STATUS"
    if is_pidfile_running "${STATE_DIR}/capture.pid"; then
        printf 'Status: \e[1;32mRUNNING\e[0m (PID %s)\n' "$(cat "${STATE_DIR}/capture.pid")"
    else
        printf 'Status: \e[1;33mSTOPPED\e[0m\n'
    fi

    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf 'Last Capture: %s\n' "${LAST_PCAP:-<none>}"
        if [[ -n "${LAST_PCAP:-}" && -f "${LAST_PCAP}" ]]; then
            local size
            size="$(du -h "${LAST_PCAP}" 2>/dev/null | cut -f1 || echo "0")"
            printf 'File Size:    %s\n' "${size}"
        fi
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
    case "${1:-status}" in
        start)  shift; start_capture "$@" ;;
        stop)   stop_capture ;;
        status) show_status ;;
        clean)  stop_capture; clean_captures ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
