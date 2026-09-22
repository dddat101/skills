#!/usr/bin/env bash
# ==============================================================================
# CANONICAL CLI SCRIPT BOILERPLATE
# Non-root graceful degradation, 6-section usage & option parsing
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Concise description of the script functionality and test objective.

Usage:
  sudo ./scripts/my_tool.sh [options] [arguments]
  ./scripts/my_tool.sh [command]
  ./scripts/my_tool.sh -h | --help

Commands:
  run              Run the tool in foreground [Default]
  status           Inspect current execution status

Options / Arguments:
  -i, --interface  Network interface to bind [Default: eth0]
  -c, --count      Number of packets/cycles to execute [Default: 10]
  -h, --help       Show this help message and exit

Examples:
  ./scripts/my_tool.sh -h
  sudo ./scripts/my_tool.sh -i eth0 -c 50
  ./scripts/my_tool.sh status

Suggested Next Steps:
  - Inspect lab state:     ./scripts/show_state.sh
  - Run verification:      ./scripts/verify_compliance.sh
  - Teardown when done:    sudo ./scripts/cleanup.sh
USAGE
}

show_status() {
    print_header "TOOL STATUS"
    printf 'Tool is ready.\n'
}

main() {
    # 1. Non-root graceful degradation: Always check help first (Exit 0)
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    # 2. Non-destructive subcommands (executable without root)
    case "${1:-}" in
        status|info)
            show_status
            exit 0
            ;;
    esac

    # 3. Privilege & dependency assertions (only when actually executing)
    require_root
    require_cmd ip

    load_config

    # 4. Parse options and arguments
    local iface="eth0"
    local count=10

    while (( $# > 0 )); do
        case "$1" in
            -i|--interface)
                shift; [[ $# -gt 0 ]] || die "Missing value for $1"; iface="$1"; shift ;;
            -c|--count)
                shift; [[ $# -gt 0 ]] || die "Missing value for $1"; count="$1"; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                usage; exit 2 ;;
        esac
    done

    # 5. Core execution logic
    print_header "EXECUTING MY TEST TOOL"
    log_info "Running test on ${iface} with count=${count}..."
    log_success "Execution completed successfully!"
}

main "$@"
