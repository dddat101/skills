# DHCP & Network Namespace Isolation

This document explains the nuances of running DHCP clients and servers inside Linux network namespaces, preventing host filesystem contamination, and managing device identity signaling.

---

## 1. DHCP Client Nuances in Namespaces

### 1.1. `udhcpc` and Custom Event Script
Unlike desktop DHCP clients, `udhcpc` (from BusyBox) does not modify network interfaces directly; it delegates interface configuration to a shell script specified via `-s <script>`.

#### The Trap: Host `/etc/resolv.conf` Overwrite
The system default script (`/usr/share/udhcpc/default.script` or `/etc/udhcpc/default.script`) typically updates `/etc/resolv.conf`. Because `/etc/resolv.conf` is shared across all namespaces on the host, a test client inside a namespace will overwrite host DNS settings!

#### The Anti-Pattern: `-s /bin/true`
To prevent overwriting DNS, engineers often run:
```bash
udhcpc -i eth0 -s /bin/true  # WRONG!
```
This prevents `/etc/resolv.conf` corruption, but `/bin/true` also ignores the `bound` event, meaning **the interface never receives the acquired IP or default gateway**.

#### The Production Solution: `scripts/lib/udhcpc.script`
The framework supplies a namespace-safe event script that configures IP and routes locally without touching host files:

```bash
#!/bin/sh
set -eu

case "${1:-}" in
    bound|renew)
        ip -4 addr flush dev "${interface}" 2>/dev/null || true
        ip -4 addr add "${ip}/${prefix:-24}" dev "${interface}" 2>/dev/null || true
        if [ -n "${router:-}" ]; then
            ip -4 route add default via "${router%% *}" dev "${interface}" 2>/dev/null || true
        fi
        ;;
    deconfig)
        ip -4 addr flush dev "${interface}" 2>/dev/null || true
        ;;
esac
```

---

### 1.2. `dhclient` Lease Database Collision
By default, ISC `dhclient` stores its state in `/var/lib/dhcp/dhclient.leases`.
When running multiple namespaces simultaneously (e.g. `ns-lan1`, `ns-lan2`), they share the same host file. If interfaces share identical names (e.g. `eth0`), `dhclient` attempts to reuse cached leases (Option 50 Requested-IP), causing address allocation collisions and unexpected NAK responses.

#### The Solution: Namespace-Isolated Leases
Always isolate lease database and PID files per namespace:

```bash
dhclient -4 -v -1 \
    -lf "${STATE_DIR}/dhclient-${NS_NAME}.leases" \
    -pf "${STATE_DIR}/dhclient-${NS_NAME}.pid" \
    "${IFACE}"
```

---

## 2. Device Identity Signaling: Hostname (Opt 12) & Vendor ID (Opt 60)

When testing CPE routers, carrier gateway Web GUIs categorize connected clients by device name (e.g. `Living-Room-STB`, `Smart-TV`) and vendor class.

Standard RFC 2132 options:
- **DHCP Option 12 (Host Name)**: Advertises device hostname.
- **DHCP Option 60 (Vendor Class Identifier)**: Identifies hardware/device profile.

### Production Invocation:
```bash
ip netns exec "${ns}" udhcpc \
    -i "${ns_if}" \
    -n -q -t 5 -T 2 \
    -s "${PROJECT_ROOT}/scripts/lib/udhcpc.script" \
    -p "${STATE_DIR}/udhcpc-${ns}.pid" \
    -x "hostname:${hostname}" -F "${hostname}" \
    -V "${vendor_id:-Carrier_STB_v2}"
```

---

## 3. Upstream WAN DHCP Server (`dnsmasq` in `ns-wan`)

Most commercial CPE routers expect an upstream DHCP server on their WAN port to acquire a public/WAN IP, gateway, and DNS.

### Safe Minimal Configuration (`state/dnsmasq_wan.conf`)
To avoid port conflicts on the host (e.g. port 53 DNS collisions):
- Disable DNS service (`port=0`).
- Lock strictly to namespace interface (`bind-interfaces`, `interface=eth-wan`).
- Supply Option 3 (Router) and Option 6 (DNS) pointing to the mock WAN gateway.
- Enable authoritative assignment.

```conf
port=0
no-resolv
no-hosts
bind-interfaces
interface=eth-wan
dhcp-range=10.10.0.20,10.10.0.80,255.255.255.0,12h
dhcp-option=option:router,10.10.0.10
dhcp-option=option:dns-server,10.10.0.10
dhcp-authoritative
log-dhcp
```
