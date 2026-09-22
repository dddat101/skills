# CLI Standards & The 4 Help Traps

Every shell script in the network lab framework must adhere to strict CLI design rules. Users and automation runners should always be able to run `./scripts/<script>.sh -h` without root, without pre-installed packages, and without existing runtime files.

---

## 1. The 4 "Help Traps" (Anti-Patterns to Avoid)

### Trap 1: Root Enforcement Trap
- **Anti-Pattern**: Invoking `require_root` at the start of `main()` or at the script root before parsing command line flags.
- **Consequence**: Users typing `./script.sh -h` are blocked with `[ERROR] This command requires root/sudo privileges`.
- **Remedy**: Always scan `$@` for `-h` and `--help` before calling `require_root`.

### Trap 2: Dependency Assertion Trap
- **Anti-Pattern**: Placing `require_cmd ffmpeg` or `require_cmd tshark` at module level (outside `main()`).
- **Consequence**: If an engineer clones the repository on a new machine and runs `./scripts/tool.sh -h`, the script crashes immediately because the binary is not yet installed.
- **Remedy**: Move `require_cmd` checks inside `main()`, strictly after help validation.

### Trap 3: Argument Hijacking Trap
- **Anti-Pattern**: Blindly assigning positional parameters (`group="${1:-239.10.10.10}"`) without screening for `-h`, or using a `case` statement where `*)` handles `-h` and exits with code 2.
- **Consequence**: The script mistakes `"-h"` for an IP address or interface, or exits with an error status instead of POSIX `0`.
- **Remedy**: Check help flags first. In `case` blocks, explicitly handle `-h|--help) usage; exit 0 ;;`.

### Trap 4: Resource Assertion Trap
- **Anti-Pattern**: Resolving runtime files (`resolve_pcap "$2"`) or asserting bridges exist before checking help options.
- **Consequence**: Running `./scripts/verify.sh -h` on a clean repository fails with `[ERROR] No capture file found`.
- **Remedy**: Never access the filesystem or kernel state before verifying that the user is not requesting help.

---

## 2. Standard 6-Section `usage()` Structure

Every script must present help in a consistent 6-block layout:

1. **Description**: 1-2 concise sentences summarizing the technical objective.
2. **Usage**: Command syntax conventions (`sudo ./scripts/... [options] [command]`).
3. **Options / Arguments**: Table or list of short flags (`-o`), long flags (`--option`), parameter types, and default values.
4. **Commands / Subcommands**: (For modular runners) Clear separation of destructive vs non-destructive commands.
5. **Examples**: 2-4 copy-pasteable command invocations.
6. **Suggested Next Steps**: 2-3 logical follow-up actions to guide the user's workflow.

---

## 3. Canonical CLI Pattern

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Executes diagnostic checks on interface parameters.

Usage:
  sudo ./scripts/tool.sh [options]
  ./scripts/tool.sh [command]
  ./scripts/tool.sh -h | --help

Options:
  -i, --interface <name>  Target interface name [Default: eth0]
  -c, --count <num>       Number of iterations [Default: 10]
  -h, --help              Show this help message and exit

Commands:
  status                  Show tool execution status

Examples:
  ./scripts/tool.sh -h
  sudo ./scripts/tool.sh -i eth-wan -c 5

Suggested Next Steps:
  - Inspect state:   ./scripts/show_state.sh
  - Run scenario:    sudo ./scripts/scenario.sh
USAGE
}

main() {
    # 1. Graceful degradation: Check help first (always exit 0)
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    # 2. Non-destructive commands (executable without root)
    case "${1:-}" in
        status) show_status; exit 0 ;;
    esac

    # 3. Privilege & dependency assertions (only when actually running)
    require_root
    require_cmd ip

    load_config

    # 4. Parse options and arguments
    local iface="eth0"
    local count=10

    while (( $# > 0 )); do
        case "$1" in
            -i|--interface) shift; [[ $# -gt 0 ]] || die "Missing value for $1"; iface="$1"; shift ;;
            -c|--count)     shift; [[ $# -gt 0 ]] || die "Missing value for $1"; count="$1"; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage; exit 2 ;;
        esac
    done

    # 5. Core execution logic
    log_info "Executing task on ${iface} with count ${count}..."
}

main "$@"
```
