#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - AUTOMATED SCENARIO RUNNER
# Evaluates Wire-rate, Rate Mismatch Bursts, STB Gaming/VOD, Simultaneous Use, QoS
# Refactored with Bash Defensive Programming Standards
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
SCENARIO_TMP_DIR=""
ACTIVE_BG_PIDS=()

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Scenario Runner
==================================================================

Description:
  Executes automated test scenarios verifying:
  - Wire-rate bidirectional unicast and multicast (1024-byte, 0% loss)
  - 1G-to-100M rate mismatch burst absorption (53 frames @ 50%, 100 frames @ 16%)
  - GeForce NOW network test & UHD+Dolby 1.2x VOD on 100M STB
  - Simultaneous Wired + Tri-band Wireless (2.4G/5G/6G, 5-trial average)
  - PC throughput stability during 2 active Wi-Fi phone calls

Usage:
  sudo ./scripts/scenario.sh [OPTIONS] [SCENARIO]

Scenarios:
  all             (Default) Run complete multi-phase test suite
  wire_rate       Phase 1: Bidirectional Unicast & Multicast wire-rate loss tests
  rate_mismatch   Phase 2: 1G -> 100M burst traffic tests (53 frames & 100 frames)
  real_world_stb  Phase 3: GeForce NOW Cloud Gaming & UHD+Dolby 1.2x VOD tests
  simultaneous    Phase 4: Simultaneous Wired & Wireless 2.4G/5G/6G (5 trials)
  voice_qos       Phase 5: PC throughput with 2 active Wi-Fi phone calls

Options:
  --dry-run, -n   Preview test parameters and phases without generating traffic
  -h, --help      Show this help message and exit

Examples:
  sudo ./scripts/scenario.sh all
  sudo ./scripts/scenario.sh rate_mismatch
  sudo ./scripts/scenario.sh simultaneous
  ./scripts/scenario.sh --dry-run all
==================================================================
EOF
}

# Defensive cleanup trap: cleans up temporary directory and background PIDs
cleanup_scenario_trap() {
    local exit_code=$?
    trap - EXIT INT TERM ERR

    # Terminate any tracked background jobs
    if (( ${#ACTIVE_BG_PIDS[@]} > 0 )); then
        for pid in "${ACTIVE_BG_PIDS[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
            fi
        done
    fi

    # Terminate any remaining test servers in ns-wan
    if ns_exists "${WAN_NS:-ns-wan}"; then
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    fi

    # Safely remove scenario temporary directory
    if [[ -n "${SCENARIO_TMP_DIR:-}" && -d "${SCENARIO_TMP_DIR}" ]]; then
        rm -rf "${SCENARIO_TMP_DIR}" 2>/dev/null || true
    fi

    if (( exit_code != 0 )); then
        log_error "Scenario runner exited with code ${exit_code}."
    fi
    exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Phase 1: Wire-rate Unicast and Multicast Forwarding
# ------------------------------------------------------------------------------
run_phase_wire_rate() {
    log_step "[PHASE 1] Wire-rate Unicast & Multicast Forwarding"
    local tools_dir="${LAB_DIR}/tools"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B bidirectional unicast at 950 Mbps between ns-wan and ns-pc"
        log_info "[DRY-RUN] Would test 1024B multicast forwarding (2,000 packets) to group ${MULTICAST_GROUP:-239.255.0.1}"
        return 0
    fi

    # Part A: Bidirectional 1024-byte Unicast
    log_info "Sub-phase 1A: Bidirectional Unicast 1024B (WAN <-> PC)..."
    local uni_json="${LOG_DIR}/unicast_result.json"

    local engine="${WIRE_RATE_ENGINE:-auto}"
    if [[ "${engine}" == "auto" ]]; then
        if check_command iperf3; then
            engine="iperf3"
        else
            engine="python"
        fi
    fi

    if [[ "${engine}" == "iperf3" ]]; then
        log_info "Using high-performance C-based engine: iperf3 UDP (-l 982, ~116k PPS)..."
        local fwd_out="${SCENARIO_TMP_DIR}/iperf_uni_fwd.json"
        local rev_out="${SCENARIO_TMP_DIR}/iperf_uni_rev.json"

        # Forward Direction: WAN -> PC
        ip netns exec "${PC_NS:-ns-pc}" pkill -TERM iperf3 2>/dev/null || true
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -s -p 5002 -D >/dev/null 2>&1
        sleep 0.3
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -c "${PC_IP:-192.168.1.10}" -u -p 5002 -b 950M -l 982 -t 3 -J > "${fwd_out}" 2>&1 || true
        ip netns exec "${PC_NS:-ns-pc}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.3

        # Reverse Direction: PC -> WAN
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p 5002 -D >/dev/null 2>&1
        sleep 0.3
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -u -p 5002 -b 950M -l 982 -t 3 -J > "${rev_out}" 2>&1 || true
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

        # Consolidate bidirectional results into standard schema
        python3 -c '
import sys, json

def parse_res(path):
    try:
        with open(path) as f: d = json.load(f)
        udp = d.get("end", {}).get("sum", {})
        rx = d.get("end", {}).get("sum_received", {}) or udp
        lost = udp.get("lost_packets", 0)
        total = udp.get("packets", 0)
        bps = rx.get("bits_per_second", 0.0)
        return total, lost, bps / 1e6
    except Exception:
        return 0, 0, 0.0

f_tot, f_lost, f_mbps = parse_res(sys.argv[1])
r_tot, r_lost, r_mbps = parse_res(sys.argv[2])

tot_pkts = f_tot + r_tot
lost_pkts = f_lost + r_lost
avg_mbps = (f_mbps + r_mbps) / 2.0 if (f_mbps > 0 and r_mbps > 0) else max(f_mbps, r_mbps)
loss_pct = (lost_pkts / tot_pkts * 100.0) if tot_pkts > 0 else 0.0
status = "PASS" if loss_pct == 0.0 and tot_pkts > 1000 else "FAIL"

res = {
    "test": "unicast_throughput",
    "engine": "iperf3_c_kernel",
    "received_packets": tot_pkts - lost_pkts,
    "throughput_mbps": round(avg_mbps, 2),
    "loss_pct": round(loss_pct, 4),
    "status": status
}
with open(sys.argv[3], "w") as f:
    json.dump(res, f, indent=2)
print(json.dumps(res, indent=2))
' "${fwd_out}" "${rev_out}" "${uni_json}"
    else
        log_info "Using native zero-allocation Python engine: traffic_generator.py..."
        # Start receiver in PC namespace
        ip netns exec "${PC_NS:-ns-pc}" "${tools_dir}/traffic_generator.py" unicast-recv \
            --bind-ip "${PC_IP:-192.168.1.10}" --bind-port 5002 --duration 6 \
            --output-json "${uni_json}" >/dev/null 2>&1 &
        local rx_pid=$!
        ACTIVE_BG_PIDS+=("${rx_pid}")
        sleep 0.2

        # Start sender in WAN namespace
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" unicast-send \
            --dest-ip "${PC_IP:-192.168.1.10}" --dest-port 5002 \
            --packet-size "${UNICAST_PACKET_SIZE:-1024}" --duration 4 --rate-mbps 950.0

        wait "${rx_pid}" || true
        if [[ -f "${uni_json}" ]]; then
            cat "${uni_json}"
        fi
    fi

    # Part B: Wire-rate 1024-byte Multicast Forwarding
    log_info "Sub-phase 1B: Multicast Forwarding 1024B (Group: ${MULTICAST_GROUP:-239.255.0.1})..."
    local mcast_json="${LOG_DIR}/multicast_result.json"

    # Start IGMP proxy forwarder in DUT namespace
    local mcast_fwd_pid=""
    if ns_exists "${DUT_NS:-ns-dut}"; then
        ip netns exec "${DUT_NS:-ns-dut}" "${tools_dir}/mcast_forwarder.py" \
            --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
            --wan-if-ip "${DUT_WAN_IP:-203.0.113.129}" --lan-if-ip "${DUT_LAN_IP:-192.168.1.1}" \
            --duration 12.0 >/dev/null 2>&1 &
        mcast_fwd_pid=$!
        ACTIVE_BG_PIDS+=("${mcast_fwd_pid}")
        sleep 0.2
    fi

    # Start multicast receiver in STB namespace
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" mcast-recv \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --expected-packets 2000 --timeout 5.0 --output-json "${mcast_json}" >/dev/null 2>&1 &
    local mcast_rx_pid=$!
    ACTIVE_BG_PIDS+=("${mcast_rx_pid}")
    # Allow 1.2s for DUT IGMP Snooping/Proxy and hardware multicast forwarding table to converge
    sleep 1.2

    # Start multicast sender in WAN namespace
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" mcast-send \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --packet-size "${MULTICAST_PACKET_SIZE:-1024}" --packets 2000 --rate-mbps 80.0

    wait "${mcast_rx_pid}" || true
    if [[ -n "${mcast_fwd_pid}" ]]; then
        kill "${mcast_fwd_pid}" 2>/dev/null || true
    fi
    if [[ -f "${mcast_json}" ]]; then
        cat "${mcast_json}"
    fi
}

# ------------------------------------------------------------------------------
# Phase 2: WAN-to-LAN Rate Mismatch & Burst Absorption (1G to 100M)
# ------------------------------------------------------------------------------
run_phase_rate_mismatch() {
    log_step "[PHASE 2] WAN-to-LAN 1G -> 100M Rate Mismatch Burst Tests"
    local tools_dir="${LAB_DIR}/tools"

    local c1_frames="${BURST_CASE1_FRAMES:-53}"
    local c1_load="${BURST_CASE1_LOAD:-50.0}"
    local c1_count="${BURST_COUNT:-20}"
    local c1_expected=$(( c1_frames * c1_count ))
    local c1_json="${LOG_DIR}/burst_case1.json"

    local c2_frames="${BURST_CASE2_FRAMES:-100}"
    local c2_load="${BURST_CASE2_LOAD:-16.0}"
    local c2_count="${BURST_COUNT:-20}"
    local c2_expected=$(( c2_frames * c2_count ))
    local c2_json="${LOG_DIR}/burst_case2.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 1: 1500B, Length=${c1_frames} frames, Load=${c1_load}%, Total=${c1_expected} frames"
        log_info "[DRY-RUN] Would test Burst Case 2: 1500B, Length=${c2_frames} frames, Load=${c2_load}%, Total=${c2_expected} frames"
        return 0
    fi

    log_info "Sub-phase 2A: Burst Case 1 (1500B, Length=${c1_frames} frames, Load=${c1_load}%, Bursts=${c1_count})..."
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "${STB_IP:-192.168.1.20}" --bind-port 5001 \
        --expected-packets "${c1_expected}" --timeout 5.0 --output-json "${c1_json}" >/dev/null 2>&1 &
    local c1_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c1_rx_pid}")
    sleep 0.2

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c1_frames}" \
        --burst-load "${c1_load}" --burst-count "${c1_count}" --rate-mbps 1000.0

    wait "${c1_rx_pid}" || true
    if [[ -f "${c1_json}" ]]; then
        cat "${c1_json}"
    fi

    log_info "Sub-phase 2B: Burst Case 2 (1500B, Length=${c2_frames} frames, Load=${c2_load}%, Bursts=${c2_count})..."
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "${STB_IP:-192.168.1.20}" --bind-port 5001 \
        --expected-packets "${c2_expected}" --timeout 5.0 --output-json "${c2_json}" >/dev/null 2>&1 &
    local c2_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c2_rx_pid}")
    sleep 0.2

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c2_frames}" \
        --burst-load "${c2_load}" --burst-count "${c2_count}" --rate-mbps 1000.0

    wait "${c2_rx_pid}" || true
    if [[ -f "${c2_json}" ]]; then
        cat "${c2_json}"
    fi
}

# ------------------------------------------------------------------------------
# Phase 3: Real-World Latency-Sensitive Applications on 100M STB
# ------------------------------------------------------------------------------
run_phase_real_world_stb() {
    log_step "[PHASE 3] Real-World Sensitive Apps (GeForce NOW & UHD+Dolby 1.2x VOD)"
    local tools_dir="${LAB_DIR}/tools"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test GeForce NOW UDP game streaming (60 FPS, 25 Mbps) on ns-stb"
        log_info "[DRY-RUN] Would test UHD+Dolby VOD @ 1.2x playback (35 Mbps x 1.2 = 42 Mbps) on ns-stb"
        return 0
    fi

    # Part A: GeForce NOW Network Test Emulation
    log_info "Sub-phase 3A: GeForce NOW Network Test Simulation..."
    local gfn_json="${LOG_DIR}/geforce_now.json"

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/geforce_now_tester.py" client \
        --bind-ip "${STB_IP:-192.168.1.20}" --bind-port 5004 --duration 5.0 \
        --max-loss-pct "${GEFORCE_NOW_MAX_LOSS_PCT:-0.0}" \
        --max-jitter-ms "${GEFORCE_NOW_MAX_JITTER_MS:-2.0}" \
        --output-json "${gfn_json}" >/dev/null 2>&1 &
    local gfn_rx_pid=$!
    ACTIVE_BG_PIDS+=("${gfn_rx_pid}")
    sleep 0.2

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/geforce_now_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5004 --duration 4.0 \
        --frame-rate "${GEFORCE_NOW_FPS:-60}" --bitrate-mbps "${GEFORCE_NOW_BITRATE_MBPS:-25.0}"

    wait "${gfn_rx_pid}" || true
    if [[ -f "${gfn_json}" ]]; then
        cat "${gfn_json}"
    fi

    # Part B: UHD+Dolby VOD 1.2x Speed Playback
    log_info "Sub-phase 3B: UHD+Dolby VOD @ 1.2x Speed Playback..."
    local vod_json="${LOG_DIR}/vod_1_2x.json"

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/vod_stream_tester.py" client \
        --bind-ip "${STB_IP:-192.168.1.20}" --bind-port 5005 --duration 5.0 \
        --output-json "${vod_json}" >/dev/null 2>&1 &
    local vod_rx_pid=$!
    ACTIVE_BG_PIDS+=("${vod_rx_pid}")
    sleep 0.2

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/vod_stream_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5005 --duration 4.0 \
        --base-bitrate-mbps "${VOD_BASE_BITRATE_MBPS:-35.0}" \
        --playback-speed "${VOD_SPEED_MULTIPLIER:-1.2}"

    wait "${vod_rx_pid}" || true
    if [[ -f "${vod_json}" ]]; then
        cat "${vod_json}"
    fi
}

# ------------------------------------------------------------------------------
# Phase 4: Simultaneous Wired & Wireless Use (2.4G + 5G + 6G + Wired, 5 Trials)
# ------------------------------------------------------------------------------
run_phase_simultaneous() {
    log_step "[PHASE 4] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${BENCHMARK_DURATION_SEC:-3}"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous)"
        log_info "[DRY-RUN] Acceptance: |C - B| / B <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # Stop any stale iperf3 instances
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    sleep 0.2

    # Start 4 iperf3 server daemons in WAN namespace
    local srv_ports=(5201 5202 5203 5204)
    for port in "${srv_ports[@]}"; do
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
    done
    sleep 0.5

    # Arrays to store trials
    local a_trials=()
    local b_trials=()
    local c_trials=()

    log_info "Executing ${trials} measurement trials..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- Trial ${i}/${trials} ---"

        # 1. Measure Wireless-only speed (A): 2.4G + 5G + 6G in parallel
        local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_${i}.json"
        local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_${i}.json"
        local w6g_out="${SCENARIO_TMP_DIR}/iperf_w6g_${i}.json"

        ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5201 -t "${duration}" -J > "${w2g_out}" 2>&1 &
        local p1=$!
        ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5202 -t "${duration}" -J > "${w5g_out}" 2>&1 &
        local p2=$!
        ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5203 -t "${duration}" -J > "${w6g_out}" 2>&1 &
        local p3=$!
        wait "${p1}" "${p2}" "${p3}" || true
        sleep 0.3

        # Defensive argument-based throughput extraction
        local a_val
        a_val="$(python3 -c '
import sys, json
def get_mbps(path):
    try:
        with open(path) as f: d = json.load(f)
        return d.get("end", {}).get("sum_received", {}).get("bits_per_second", 0.0) / 1e6
    except Exception: return 0.0
total = sum(get_mbps(p) for p in sys.argv[1:])
print(round(total, 2))
' "${w2g_out}" "${w5g_out}" "${w6g_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Wireless-only (A): ${a_val} Mbps"

        # 2. Measure Wired-only speed (B): PC
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1
        sleep 0.3
        local b_val
        b_val="$(python3 -c '
import sys, json
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(round(d.get("end", {}).get("sum_received", {}).get("bits_per_second", 0.0) / 1e6, 2))
except Exception: print(0.0)
' "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Wired-only (B): ${b_val} Mbps"

        # 3. Measure Simultaneous Wired + Wireless speed (C): PC + 2.4G + 5G + 6G in parallel
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
        local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"
        local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
        local sim_w6g_out="${SCENARIO_TMP_DIR}/iperf_sim_w6g_${i}.json"

        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5202 -t "${duration}" -J > "${sim_w2g_out}" 2>&1 &
        local sp1=$!
        ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5203 -t "${duration}" -J > "${sim_w5g_out}" 2>&1 &
        local sp2=$!
        ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5204 -t "${duration}" -J > "${sim_w6g_out}" 2>&1 &
        local sp3=$!
        wait "${sp0}" "${sp1}" "${sp2}" "${sp3}" || true
        sleep 0.3

        local c_val
        c_val="$(python3 -c '
import sys, json
def get_mbps(path):
    try:
        with open(path) as f: d = json.load(f)
        return d.get("end", {}).get("sum_received", {}).get("bits_per_second", 0.0) / 1e6
    except Exception: return 0.0
total = sum(get_mbps(p) for p in sys.argv[1:])
print(round(total, 2))
' "${sim_pc_out}" "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
        c_trials+=("${c_val}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps"
    done

    # Kill iperf3 servers
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

    # Compute averages and 1% threshold defensively
    python3 -c '
import sys, json
a_str, b_str, c_str, tol_str, out_path = sys.argv[1:6]

a_list = [float(x) for x in a_str.split() if x]
b_list = [float(x) for x in b_str.split() if x]
c_list = [float(x) for x in c_str.split() if x]

avg_a = sum(a_list) / len(a_list) if a_list else 0.0
avg_b = sum(b_list) / len(b_list) if b_list else 0.0
avg_c = sum(c_list) / len(c_list) if c_list else 0.0

diff_pct = abs(avg_c - avg_b) / avg_b * 100.0 if avg_b > 0 else 0.0
tol = float(tol_str)
verdict = "PASS" if diff_pct <= tol else "FAIL"

result = {
    "test": "simultaneous_wired_wireless_benchmark",
    "trials": len(a_list),
    "wireless_only_avg_mbps": round(avg_a, 2),
    "wired_only_avg_mbps": round(avg_b, 2),
    "simultaneous_sum_avg_mbps": round(avg_c, 2),
    "diff_percentage": round(diff_pct, 3),
    "tolerance_threshold_pct": tol,
    "verdict": verdict
}

print(json.dumps(result, indent=2))
with open(out_path, "w") as f:
    json.dump(result, f, indent=2)
' "${a_trials[*]:-}" "${b_trials[*]:-}" "${c_trials[*]:-}" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}" "${sim_json}"
}

# ------------------------------------------------------------------------------
# Phase 5: Wired PC Throughput with Concurrent Wi-Fi Phone Calls
# ------------------------------------------------------------------------------
run_phase_voice_qos() {
    log_step "[PHASE 5] Wired PC Throughput with 2 Active Wi-Fi Phone Calls"
    local tools_dir="${LAB_DIR}/tools"
    local voice_json="${LOG_DIR}/voice_pc_qos.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test PC throughput with and without 2 active G.711 RTP VoIP calls"
        log_info "[DRY-RUN] Acceptance: |A - B| / A <= ${VOIP_IMPACT_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # Start iperf3 server in ns-wan
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p 5201 -D >/dev/null 2>&1
    sleep 0.3

    # Step 1: Baseline PC Throughput (A)
    log_info "Measuring baseline PC throughput without VoIP calls (A)..."
    local pc_base_out="${SCENARIO_TMP_DIR}/iperf_pc_base.json"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5201 -t 4 -J > "${pc_base_out}" 2>&1
    local a_mbps
    a_mbps="$(python3 -c '
import sys, json
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(round(d.get("end", {}).get("sum_received", {}).get("bits_per_second", 0.0) / 1e6, 2))
except Exception: print(0.0)
' "${pc_base_out}")"
    log_info "  Baseline PC throughput (A): ${a_mbps} Mbps"

    # Step 2: Start VoIP server and 2 Wi-Fi phone calls in background
    log_info "Starting VoIP media server and 2 active Wi-Fi phone calls..."
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/voip_call_simulator.py" server \
        --ports "10000,10002" --duration 30.0 >/dev/null 2>&1 &
    local voip_srv_pid=$!
    ACTIVE_BG_PIDS+=("${voip_srv_pid}")
    sleep 0.3

    ip netns exec "${PHONE1_NS:-ns-phone1}" "${tools_dir}/voip_call_simulator.py" client \
        --server-ip "${WAN_SERVER_IP:-203.0.113.1}" --server-port 10000 \
        --duration 15.0 --phone-id "phone-1" >/dev/null 2>&1 &
    local phone1_pid=$!
    ACTIVE_BG_PIDS+=("${phone1_pid}")

    ip netns exec "${PHONE2_NS:-ns-phone2}" "${tools_dir}/voip_call_simulator.py" client \
        --server-ip "${WAN_SERVER_IP:-203.0.113.1}" --server-port 10002 \
        --duration 15.0 --phone-id "phone-2" >/dev/null 2>&1 &
    local phone2_pid=$!
    ACTIVE_BG_PIDS+=("${phone2_pid}")

    sleep 1.0 # Allow calls to establish and stabilize

    # Step 3: Measure PC Throughput during active calls (B)
    log_info "Measuring PC throughput during 2 active Wi-Fi phone calls (B)..."
    local pc_call_out="${SCENARIO_TMP_DIR}/iperf_pc_call.json"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-203.0.113.1}" -p 5201 -t 4 -J > "${pc_call_out}" 2>&1
    local b_mbps
    b_mbps="$(python3 -c '
import sys, json
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(round(d.get("end", {}).get("sum_received", {}).get("bits_per_second", 0.0) / 1e6, 2))
except Exception: print(0.0)
' "${pc_call_out}")"
    log_info "  Concurrent PC throughput (B): ${b_mbps} Mbps"

    # Clean up background VoIP processes and iperf server
    kill "${phone1_pid}" "${phone2_pid}" "${voip_srv_pid}" 2>/dev/null || true
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

    # Compute difference and verdict defensively
    python3 -c '
import sys, json
a_str, b_str, tol_str, out_path = sys.argv[1:5]
a = float(a_str)
b = float(b_str)
diff_pct = abs(a - b) / a * 100.0 if a > 0 else 0.0
tol = float(tol_str)
verdict = "PASS" if diff_pct <= tol else "FAIL"

result = {
    "test": "pc_throughput_during_voip_calls",
    "pc_baseline_mbps": a,
    "pc_during_calls_mbps": b,
    "diff_percentage": round(diff_pct, 3),
    "tolerance_threshold_pct": tol,
    "verdict": verdict
}

print(json.dumps(result, indent=2))
with open(out_path, "w") as f:
    json.dump(result, f, indent=2)
' "${a_mbps}" "${b_mbps}" "${VOIP_IMPACT_TOLERANCE_PCT:-1.0}" "${voice_json}"
}

main() {
    local scenario="all"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            wire_rate|rate_mismatch|real_world_stb|simultaneous|voice_qos|all)
                scenario="$1"
                shift
                ;;
            *)
                log_error "Unknown option or scenario: $1"
                usage
                exit 1
                ;;
        esac
    done

    load_config "${LAB_DIR}/config.env"

    if (( DRY_RUN == 0 )); then
        require_root
        require_command ip
        require_command python3
        require_command iperf3
    fi

    ensure_runtime_dirs

    # Defensive temporary directory isolation
    SCENARIO_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gw_perf_scenario.XXXXXX")"
    trap cleanup_scenario_trap EXIT INT TERM ERR

    print_header "STARTING GATEWAY PERFORMANCE TEST: [${scenario^^}]"

    if (( DRY_RUN == 0 )); then
        # Ensure WAN route to LAN subnet exists in ns-wan and DUT allows bidirectional traffic
        if ns_exists "${WAN_NS:-ns-wan}"; then
            ip -n "${WAN_NS:-ns-wan}" route replace "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
            ip -n "${WAN_NS:-ns-wan}" route replace default via "${DUT_WAN_IP:-203.0.113.129}" dev eth0 2>/dev/null || true
            ip -n "${WAN_NS:-ns-wan}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        fi
        if ns_exists "${DUT_NS:-ns-dut}"; then
            ip netns exec "${DUT_NS:-ns-dut}" iptables -P FORWARD ACCEPT 2>/dev/null || true
            ip netns exec "${DUT_NS:-ns-dut}" iptables -A FORWARD -j ACCEPT 2>/dev/null || true
            ip -n "${DUT_NS:-ns-dut}" route replace 224.0.0.0/4 dev br-lan 2>/dev/null || true
        fi
    fi

    # Background capture trigger
    local pcap_file=""
    if (( DRY_RUN == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        pcap_file="${CAPTURE_DIR}/perf_test_${scenario}_$(date +%s).pcap"
        log_info "Starting background packet capture to ${pcap_file}..."
        "${SCRIPT_DIR}/capture.sh" start "${pcap_file}" || true
    fi

    case "${scenario}" in
        wire_rate)
            run_phase_wire_rate
            ;;
        rate_mismatch)
            run_phase_rate_mismatch
            ;;
        real_world_stb)
            run_phase_real_world_stb
            ;;
        simultaneous)
            run_phase_simultaneous
            ;;
        voice_qos)
            run_phase_voice_qos
            ;;
        all)
            run_phase_wire_rate
            run_phase_rate_mismatch
            run_phase_real_world_stb
            run_phase_simultaneous
            run_phase_voice_qos
            ;;
    esac

    # Stop packet capture
    if (( DRY_RUN == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        log_info "Stopping background packet capture..."
        "${SCRIPT_DIR}/capture.sh" stop || true
    fi

    log_success "Scenario run complete. Summary logs generated in ${LOG_DIR}/."
    printf '\nSuggested next steps:\n'
    printf '  - Run compliance verifier: ./scripts/verify_compliance.sh\n'
    printf '  - Inspect running state:    ./scripts/show_state.sh\n'
}

main "$@"
