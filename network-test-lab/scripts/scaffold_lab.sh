#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - SCAFFOLDING UTILITY
# Generates a production-ready, standardized network test lab in seconds
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMPLATES_DIR="${SKILL_DIR}/templates"

usage() {
    cat <<'EOF'
==================================================================
  Network Test Lab - Project Scaffolder
==================================================================

Description:
  Generates a production-standard Linux Network Test Lab skeleton
  complete with bash strict mode libraries, setup/cleanup scripts,
  packet capture lifecycle, diagnostic tools, and PCAP verification.

Usage:
  ./scripts/scaffold_lab.sh <target_directory> [OPTIONS]
  ./scripts/scaffold_lab.sh -h | --help

Options:
  --virtual, -v    Configure default topology to Virtual / No-DUT simulation [Default]
  --single, -s     Configure default topology to Single-PC Dual-NIC physical mode
  -h, --help       Show this help message and exit

Examples:
  ./scripts/scaffold_lab.sh /home/dddat/workspace/dhcp_snooping_lab --virtual
  ./scripts/scaffold_lab.sh ./my_vlan_lab --single

Suggested Next Steps:
  1. cd into generated lab directory
  2. Review and adjust config.env
  3. Run pre-flight check:  ./scripts/diagnose.sh
  4. Initialize topology:   sudo ./scripts/setup.sh
==================================================================
EOF
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local target_dir="$1"; shift
    local default_mode="virtual"

    while (( $# > 0 )); do
        case "$1" in
            --virtual|-v) default_mode="virtual"; shift ;;
            --single|-s)  default_mode="physical"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
    done

    local lab_name
    lab_name="$(basename "${target_dir}")"

    echo "===> Scaffolding Network Test Lab: ${lab_name} in ${target_dir}"

    # 1. Create directory tree
    mkdir -p "${target_dir}"/{captures,logs,state,tools,docs,scripts/lib,config/kea,config/radvd}
    touch "${target_dir}/captures/.gitkeep"
    touch "${target_dir}/logs/.gitkeep"
    touch "${target_dir}/state/.gitkeep"

    # 2. Copy boilerplate templates
    cp "${TEMPLATES_DIR}/gitignore.template" "${target_dir}/.gitignore"
    cp "${TEMPLATES_DIR}/config.env.example" "${target_dir}/config.env.example"
    cp "${TEMPLATES_DIR}/config.env.example" "${target_dir}/config.env"
    cp "${TEMPLATES_DIR}/common.sh" "${target_dir}/scripts/lib/common.sh"
    cp "${TEMPLATES_DIR}/udhcpc.script" "${target_dir}/scripts/lib/udhcpc.script"
    cp "${TEMPLATES_DIR}/kea-dhcp4.conf.in" "${target_dir}/config/kea/kea-dhcp4.conf.in"
    cp "${TEMPLATES_DIR}/kea-dhcp6.conf.in" "${target_dir}/config/kea/kea-dhcp6.conf.in"
    cp "${TEMPLATES_DIR}/radvd.conf.in" "${target_dir}/config/radvd/radvd.conf.in"
    cp "${TEMPLATES_DIR}/setup.sh" "${target_dir}/scripts/setup.sh"
    cp "${TEMPLATES_DIR}/cleanup.sh" "${target_dir}/scripts/cleanup.sh"
    cp "${TEMPLATES_DIR}/capture.sh" "${target_dir}/scripts/capture.sh"
    cp "${TEMPLATES_DIR}/show_state.sh" "${target_dir}/scripts/show_state.sh"
    cp "${TEMPLATES_DIR}/diagnose.sh" "${target_dir}/scripts/diagnose.sh"
    cp "${TEMPLATES_DIR}/scenario.sh" "${target_dir}/scripts/scenario.sh"
    cp "${TEMPLATES_DIR}/verify_compliance.sh" "${target_dir}/scripts/verify_compliance.sh"

    # Configure topology mode default
    if [[ "${default_mode}" == "virtual" ]]; then
        sed -i 's/TOPOLOGY_MODE="physical"/TOPOLOGY_MODE="virtual"/' "${target_dir}/config.env"
    else
        sed -i 's/TOPOLOGY_MODE="virtual"/TOPOLOGY_MODE="physical"/' "${target_dir}/config.env"
    fi

    # 3. Create documentation files
    cat >"${target_dir}/docs/SHELL_STYLE.md" <<'EOF'
# Shell Scripting Guidelines

1. 100% Bash scripts with `set -Eeuo pipefail` and `IFS=$'\n\t'`.
2. Wrap pipelines against SIGPIPE (141): `(cmd 2>/dev/null || true) | head -n1`.
3. Support `-h` and `--help` for non-root users with exit code 0.
4. Quoted environment variables in `config.env`.
5. Deterministic waiting (`wait_for_port`) instead of arbitrary sleeps.
EOF

    cat >"${target_dir}/docs/TEST_PLAN.md" <<EOF
# Test Plan - ${lab_name}

## Test Matrix
| ID | Phase | Objective | PASS Criteria |
| :--- | :--- | :--- | :--- |
| TC_01 | Discovery | Validate network addressing & handshake | Frame exchange confirmed in PCAP |
| TC_02 | Forwarding | Validate data plane forwarding | Traffic reaches destination |
| TC_03 | Isolation | Validate unauthorized access block | Unauthorized packets dropped |
EOF

    cat >"${target_dir}/README.md" <<EOF
# ${lab_name}

Carrier Network Test Lab for testing Linux networking, protocol conformance, and DUT behavior.

\`\`\`mermaid
sequenceDiagram
    autonumber
    Client->>DUT: Control Frame (Discovery / Join)
    Note over DUT: State & Forwarding Table Update
    DUT->>Server: Forwarded Uplink Frame
    Server-->>DUT: Protocol Reply / Data Stream
    DUT-->>Client: Forwarded Downlink Frame
\`\`\`

## Quick Start

\`\`\`bash
# 1. Pre-flight diagnostics
./scripts/diagnose.sh

# 2. Initialize topology (${default_mode} mode)
sudo ./scripts/setup.sh --${default_mode}

# 3. Inspect runtime state
./scripts/show_state.sh

# 4. Execute test scenarios
sudo ./scripts/scenario.sh all

# 5. Verify PCAP compliance
./scripts/verify_compliance.sh

# 6. Teardown when finished
sudo ./scripts/cleanup.sh
\`\`\`
EOF

    # 4. Permissions
    chmod +x "${target_dir}"/scripts/*.sh "${target_dir}"/scripts/lib/*.sh "${target_dir}"/scripts/lib/*.script
    chmod 0777 "${target_dir}/captures" "${target_dir}/logs" "${target_dir}/state" 2>/dev/null || true

    echo "===> Test lab scaffolding complete at: ${target_dir}"
    echo "     Topology mode: ${default_mode}"
    echo ""
    echo "Suggested Next Steps:"
    echo "  1. cd ${target_dir}"
    echo "  2. ./scripts/diagnose.sh"
    echo "  3. sudo ./scripts/setup.sh --${default_mode}"
}

main "$@"
