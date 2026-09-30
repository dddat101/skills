#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - LAN CLIENT DHCP MANAGER
# Controls dynamic DHCP client leasing inside LAN device namespaces (PC, STB, Phones)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  Gateway Performance Lab - LAN Client DHCP Manager
==================================================================

Description:
  Manages DHCP client lifecycle (udhcpc / dhclient) inside LAN namespaces
  (ns-pc, ns-stb, ns-wlan*, ns-phone*) to acquire dynamic IP addressing
  and default routes from the Gateway DUT LAN DHCP server (br0).

Usage:
  sudo ./scripts/client_dhcp.sh renew [target]
  sudo ./scripts/client_dhcp.sh release [target]
  ./scripts/client_dhcp.sh status
  ./scripts/client_dhcp.sh -h | --help

Targets:
  all               All active LAN namespaces (PC, STB, Wi-Fi, Phones) [Default]
  pc                Gigabit Wired PC (ns-pc)
  stb               IPTV Set-Top Box (ns-stb)
  phone             Both Wi-Fi Phones (ns-phone1, ns-phone2)
  wlan              Simulated Wireless Clients (ns-wlan2g, ns-wlan5g, ns-wlan6g)
  <namespace>       Explicit namespace name (e.g. ns-pc, ns-stb)

Commands:
  renew [target]    Request / renew DHCP lease from DUT LAN DHCP server
  release [target]  Release DHCP lease and stop DHCP client daemons
  status            Display LAN client IP addresses, gateways, and DHCP status
  -h, --help        Show this help message and exit

Examples:
  ./scripts/client_dhcp.sh -h
  sudo ./scripts/client_dhcp.sh renew
  sudo ./scripts/client_dhcp.sh renew pc
  sudo ./scripts/client_dhcp.sh renew stb
  ./scripts/client_dhcp.sh status
  sudo ./scripts/client_dhcp.sh release

Suggested Next Steps:
  1. Verify LAN status:        ./scripts/client_dhcp.sh status
  2. Run test scenario:        sudo ./scripts/scenario.sh all
  3. Verify compliance:        ./scripts/verify_compliance.sh
==================================================================
USAGE
}

# Resolve list of (namespace, target_key, static_ip, hostname, vendor_id) tuples
resolve_targets() {
    local target="${1:-all}"
    local list=()

    case "${target}" in
        pc)
            list+=("${PC_NS:-ns-pc}:pc:${PC_IP:-192.168.1.10}:LAN-PC-Giga:PC_x86_64")
            ;;
        stb)
            list+=("${STB_NS:-ns-stb}:stb:${STB_IP:-192.168.1.20}:IPTV-STB-LivingRoom:IPTV_STB_4K")
            ;;
        phone)
            list+=("${PHONE1_NS:-ns-phone1}:phone1:${PHONE1_IP:-192.168.1.41}:VoIP-Phone-1:VoIP_SIP_G711")
            list+=("${PHONE2_NS:-ns-phone2}:phone2:${PHONE2_IP:-192.168.1.42}:VoIP-Phone-2:VoIP_SIP_G711")
            ;;
        wlan)
            list+=("${WLAN2G_NS:-ns-wlan2g}:wlan2g:${WLAN2G_IP:-192.168.1.31}:WiFi-Client-2G:WiFi_80211")
            list+=("${WLAN5G_NS:-ns-wlan5g}:wlan5g:${WLAN5G_IP:-192.168.1.32}:WiFi-Client-5G:WiFi_80211")
            list+=("${WLAN6G_NS:-ns-wlan6g}:wlan6g:${WLAN6G_IP:-192.168.1.33}:WiFi-Client-6G:WiFi_80211")
            ;;
        all)
            list+=(
                "${PC_NS:-ns-pc}:pc:${PC_IP:-192.168.1.10}:LAN-PC-Giga:PC_x86_64"
                "${STB_NS:-ns-stb}:stb:${STB_IP:-192.168.1.20}:IPTV-STB-LivingRoom:IPTV_STB_4K"
                "${WLAN2G_NS:-ns-wlan2g}:wlan2g:${WLAN2G_IP:-192.168.1.31}:WiFi-Client-2G:WiFi_80211"
                "${WLAN5G_NS:-ns-wlan5g}:wlan5g:${WLAN5G_IP:-192.168.1.32}:WiFi-Client-5G:WiFi_80211"
                "${WLAN6G_NS:-ns-wlan6g}:wlan6g:${WLAN6G_IP:-192.168.1.33}:WiFi-Client-6G:WiFi_80211"
                "${PHONE1_NS:-ns-phone1}:phone1:${PHONE1_IP:-192.168.1.41}:VoIP-Phone-1:VoIP_SIP_G711"
                "${PHONE2_NS:-ns-phone2}:phone2:${PHONE2_IP:-192.168.1.42}:VoIP-Phone-2:VoIP_SIP_G711"
            )
            ;;
        *)
            # Specific custom namespace
            list+=("${target}:custom:192.168.1.100:Generic-Client:Client_Generic")
            ;;
    esac

    printf '%s\n' "${list[@]}"
}

get_ns_interface() {
    local ns="$1"
    local iface="eth0"
    if ns_exists "${ns}"; then
        if ip -n "${ns}" link show dev eth0 >/dev/null 2>&1; then
            iface="eth0"
        else
            iface="$(ip -n "${ns}" -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}' || echo "eth0")"
        fi
    fi
    printf '%s' "${iface}"
}

renew_client() {
    local target="${1:-all}"
    require_root
    load_config
    ensure_runtime_dirs

    local udhcpc_script="${SCRIPT_DIR}/lib/udhcpc.script"
    if [[ ! -x "${udhcpc_script}" ]]; then
        chmod +x "${udhcpc_script}" 2>/dev/null || true
    fi

    local lines=()
    mapfile -t lines < <(resolve_targets "${target}")

    log_info "Initiating DHCP client lease requests for target: [${target}]..."

    local entry ns key static_ip hostname vendor_id iface pidfile logfile
    for entry in "${lines[@]}"; do
        IFS=':' read -r ns key static_ip hostname vendor_id <<< "${entry}"

        if ! ns_exists "${ns}"; then
            continue
        fi

        iface="$(get_ns_interface "${ns}")"
        pidfile="${STATE_DIR}/udhcpc-${ns}.pid"
        logfile="${LOG_DIR}/udhcpc-${ns}.log"

        # Stop any existing DHCP client in namespace
        stop_pidfile "${pidfile}"
        ip netns exec "${ns}" pkill -TERM udhcpc 2>/dev/null || true
        ip netns exec "${ns}" pkill -TERM dhclient 2>/dev/null || true

        log_info "Requesting DHCP lease on ${ns}:${iface} (Hostname: ${hostname})..."

        local acquired=0
        if command -v udhcpc >/dev/null 2>&1; then
            # udhcpc: -n (exit if lease not obtained), -q (quit after lease), -t 5 -T 2 (max ~10s wait)
            ip netns exec "${ns}" udhcpc \
                -i "${iface}" \
                -n -q -t 5 -T 2 \
                -s "${udhcpc_script}" \
                -p "${pidfile}" \
                -x "hostname:${hostname}" -F "${hostname}" \
                -V "${vendor_id}" > "${logfile}" 2>&1 || true

            # If background daemon desired, re-run with -b
            if [[ -f "${pidfile}" ]] && is_pidfile_running "${pidfile}"; then
                acquired=1
            fi
        elif command -v dhclient >/dev/null 2>&1; then
            local leasefile="${STATE_DIR}/dhclient-${ns}.leases"
            local dhclient_pid="${STATE_DIR}/dhclient-${ns}.pid"
            ip netns exec "${ns}" dhclient -4 -v -1 \
                -lf "${leasefile}" \
                -pf "${dhclient_pid}" \
                "${iface}" > "${logfile}" 2>&1 || true
            if is_pidfile_running "${dhclient_pid}"; then
                acquired=1
            fi
        fi

        # Check acquired IPv4 address
        local current_ip
        current_ip="$(ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo "")"

        if [[ -n "${current_ip}" && "${current_ip}" != "${static_ip}" ]]; then
            local current_gw
            current_gw="$(ip netns exec "${ns}" ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1 || echo "")"
            log_success "DHCP lease acquired on ${ns}:${iface} -> IP: ${current_ip} (Gateway: ${current_gw:-none})"
        elif [[ -n "${current_ip}" ]]; then
            log_success "Interface ${ns}:${iface} configured with IP: ${current_ip}"
        else
            log_warn "DHCP discovery timed out on ${ns}:${iface}; falling back to static IP: ${static_ip}/${LAN_PREFIX:-24}..."
            ip -n "${ns}" addr add "${static_ip}/${LAN_PREFIX:-24}" dev "${iface}" 2>/dev/null || true
            ip -n "${ns}" route replace default via "${DUT_LAN_IP:-192.168.1.1}" dev "${iface}" 2>/dev/null || true
        fi
    done

    log_success "LAN DHCP client configuration completed."
}

release_client() {
    local target="${1:-all}"
    require_root
    load_config

    local lines=()
    mapfile -t lines < <(resolve_targets "${target}")

    log_info "Releasing DHCP client leases and stopping daemons for target: [${target}]..."

    local entry ns key static_ip hostname vendor_id iface pidfile
    for entry in "${lines[@]}"; do
        IFS=':' read -r ns key static_ip hostname vendor_id <<< "${entry}"

        if ! ns_exists "${ns}"; then
            continue
        fi

        iface="$(get_ns_interface "${ns}")"
        pidfile="${STATE_DIR}/udhcpc-${ns}.pid"

        stop_pidfile "${pidfile}"
        ip netns exec "${ns}" pkill -TERM udhcpc 2>/dev/null || true
        ip netns exec "${ns}" pkill -TERM dhclient 2>/dev/null || true
        stop_pidfile "${STATE_DIR}/dhclient-${ns}.pid"

        log_info "Released DHCP on ${ns}:${iface}"
    done

    log_success "DHCP client release completed."
}

show_status() {
    load_config
    print_header "LAN CLIENT NETWORK & DHCP STATUS"

    local targets=(
        "${PC_NS:-ns-pc}:Gigabit PC"
        "${STB_NS:-ns-stb}:IPTV Set-Top Box"
        "${WLAN2G_NS:-ns-wlan2g}:Wi-Fi 2.4G Client"
        "${WLAN5G_NS:-ns-wlan5g}:Wi-Fi 5G Client"
        "${WLAN6G_NS:-ns-wlan6g}:Wi-Fi 6G Client"
        "${PHONE1_NS:-ns-phone1}:VoIP Phone 1"
        "${PHONE2_NS:-ns-phone2}:VoIP Phone 2"
    )

    printf '%-14s %-20s %-8s %-16s %-16s %-12s\n' "Namespace" "Role / Device" "IFace" "Current IP" "Default Gateway" "DHCP Mode"
    printf '%s\n' "--------------------------------------------------------------------------------------------------"

    local entry ns desc iface cur_ip cur_gw pidfile dhcp_mode
    for entry in "${targets[@]}"; do
        ns="${entry%%:*}"
        desc="${entry#*:}"

        if ! ns_exists "${ns}"; then
            printf '%-14s %-20s %-8s %-16s %-16s %-12s\n' "${ns}" "${desc}" "-" "[NOT FOUND]" "-" "INACTIVE"
            continue
        fi

        iface="$(get_ns_interface "${ns}")"
        cur_ip="$(ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo "-")"
        cur_gw="$(ip netns exec "${ns}" ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1 || echo "-")"
        pidfile="${STATE_DIR}/udhcpc-${ns}.pid"

        if is_pidfile_running "${pidfile}"; then
            dhcp_mode="DHCP (Active)"
        elif [[ -f "${STATE_DIR}/dhclient-${ns}.pid" ]] && is_pidfile_running "${STATE_DIR}/dhclient-${ns}.pid"; then
            dhcp_mode="DHCP (Active)"
        elif [[ -n "${cur_ip}" && "${cur_ip}" != "-" ]]; then
            dhcp_mode="STATIC"
        else
            dhcp_mode="UNCONFIGURED"
        fi

        printf '%-14s %-20s %-8s %-16s %-16s %-12s\n' "${ns}" "${desc}" "${iface}" "${cur_ip}" "${cur_gw}" "${dhcp_mode}"
    done
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

    local cmd="${1:-status}"
    local target="${2:-all}"

    case "${cmd}" in
        renew|start|request)
            renew_client "${target}"
            ;;
        release|stop)
            release_client "${target}"
            ;;
        status)
            show_status
            ;;
        *)
            log_error "Unknown command: ${cmd}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
