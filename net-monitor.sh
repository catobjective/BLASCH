#!/bin/bash
# =============================================================================
# net-monitor.sh — Detect unknown hosts on the network using arp-scan
#
# Requirements:
#   apt install arp-scan curl
#
# Usage:
#   sudo ./net-monitor.sh              — scan and alert
#   sudo ./net-monitor.sh --learn      — add all currently visible hosts to known_hosts
#   sudo ./net-monitor.sh --dry-run    — scan, report findings, and send a test notification
#   sudo ./net-monitor.sh --test       — send a test notification only (no scan)
#   sudo ./net-monitor.sh --show       — show known hosts list
#
# Configuration:
#   All settings are in net-monitor.conf next to this script.
#
# Cron (every 5 minutes):
#   */5 * * * * /root/blasch/net-monitor.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONF_FILE="${SCRIPT_DIR}/net-monitor.conf"

# ─── Load configuration ────────────────────────────────────────────────────

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Config file not found: ${CONF_FILE}"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Validate required settings
for var in INTERFACE KNOWN_HOSTS_FILE SEEN_UNKNOWN_FILE; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} is not set in ${CONF_FILE}"
        exit 1
    fi
done

# Defaults for optional settings
REALERT_HOURS="${REALERT_HOURS:-1}"
LOG_PREFIX="${LOG_PREFIX:-[net-monitor]}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
SUBNET="${SUBNET:-}"

# ─── Internal variables ────────────────────────────────────────────────────

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
    echo "${TIMESTAMP} ${LOG_PREFIX} $*"
}

# ─── Check dependencies ────────────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in arp-scan curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: Missing: ${missing[*]}. Install with: apt install ${missing[*]}"
        exit 1
    fi
}

# ─── Initialize directories ────────────────────────────────────────────────

init_dirs() {
    mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
    mkdir -p "$(dirname "$SEEN_UNKNOWN_FILE")"
    touch "$KNOWN_HOSTS_FILE"
    touch "$SEEN_UNKNOWN_FILE"
}

# ─── Network scan ───────────────────────────────────────────────────────────

scan_network() {
    local scan_args=("--interface=$INTERFACE" "--retry=3")

    if [[ -n "$SUBNET" ]]; then
        scan_args+=("$SUBNET")
    else
        scan_args+=("--localnet")
    fi

    local raw_output
    if ! raw_output="$(arp-scan "${scan_args[@]}" 2>&1)"; then
        log "arp-scan exited with error. Output:"
        log "$raw_output"
        return 1
    fi

    if [[ -z "$raw_output" ]]; then
        log "arp-scan returned empty output."
        return 1
    fi

    if [[ "${NET_MONITOR_DEBUG:-0}" == "1" ]]; then
        log "=== RAW arp-scan output ==="
        log "$raw_output"
        log "=== END ==="
    fi

    echo "$raw_output" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | awk -F'\t' '{print toupper($2) "|" $1 "|" $3}' \
        || true
}

# ─── Check if MAC is known ─────────────────────────────────────────────────

is_known_host() {
    local mac="$1"
    local ip="$2"

    while IFS='|' read -r known_mac known_ip known_desc; do
        [[ "$known_mac" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$known_mac" ]] && continue

        known_mac="$(echo "$known_mac" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

        if [[ "$known_mac" == "$mac" ]]; then
            return 0
        fi
    done < "$KNOWN_HOSTS_FILE"

    return 1
}

# ─── Check if alert was already sent ───────────────────────────────────────

already_alerted() {
    local mac="$1"
    local ip="$2"
    local now
    now="$(date +%s)"
    local threshold=$(( REALERT_HOURS * 3600 ))

    local temp_file
    temp_file="$(mktemp)"
    while IFS='|' read -r seen_mac seen_time seen_ip; do
        [[ -z "$seen_mac" ]] && continue
        if (( now - seen_time < threshold )); then
            echo "${seen_mac}|${seen_time}|${seen_ip}" >> "$temp_file"
        fi
    done < "$SEEN_UNKNOWN_FILE"
    mv "$temp_file" "$SEEN_UNKNOWN_FILE"

    # Must match both MAC and IP — IP change triggers a new alert
    grep -qi "^${mac}|[0-9]*|${ip}$" "$SEEN_UNKNOWN_FILE" 2>/dev/null || return 1
}

mark_alerted() {
    local mac="$1"
    local ip="$2"
    sed -i "/^${mac}|/Id" "$SEEN_UNKNOWN_FILE" 2>/dev/null || true
    echo "${mac}|$(date +%s)|${ip}" >> "$SEEN_UNKNOWN_FILE"
}

# ─── Send Discord webhook ──────────────────────────────────────────────────

send_discord() {
    local title="$1"
    local description="$2"
    local color="${3:-15158332}"

    if [[ -z "$WEBHOOK_URL" ]]; then
        log "No WEBHOOK_URL configured in ${CONF_FILE} — skipping notification."
        return 1
    fi

    local payload
    payload=$(cat <<EOF
{
    "embeds": [{
        "title": "${title}",
        "description": "${description}",
        "color": ${color},
        "footer": {"text": "net-monitor on $(hostname)"},
        "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    }]
}
EOF
)

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 10 \
        "$WEBHOOK_URL") || true

    if [[ "$http_code" =~ ^2 ]]; then
        log "Discord webhook sent successfully (HTTP ${http_code})"
        return 0
    else
        log "ERROR: Discord webhook failed (HTTP ${http_code})"
        return 1
    fi
}

# ─── Send alert ─────────────────────────────────────────────────────────────

send_alert() {
    local mac="$1"
    local ip="$2"
    local vendor="$3"

    log "ALERT: Unknown host detected! IP=${ip} MAC=${mac} Vendor=${vendor} Interface=${INTERFACE}"

    local desc="**IP:** ${ip}\n**MAC:** ${mac}\n**Vendor:** ${vendor}\n**Interface:** ${INTERFACE}"
    send_discord "⚠️ Unknown host detected" "$desc" "15158332" || true
}

# ─── Test notification ──────────────────────────────────────────────────────

send_test_notification() {
    local desc="This is a **test notification** from net-monitor.\\n**Host:** $(hostname)\\n**Interface:** ${INTERFACE}\\n**Subnet:** ${SUBNET:-auto}\\n**Time:** ${TIMESTAMP}"
    send_discord "🔔 net-monitor test" "$desc" "3066993"
}

# ─── Learn mode ─────────────────────────────────────────────────────────────

do_learn() {
    log "LEARN mode — scanning network and adding hosts to known_hosts..."

    local scan_results=""
    scan_results="$(scan_network)" || true

    if [[ -z "$scan_results" ]]; then
        log "ERROR: No scan results. Check interface ${INTERFACE} and permissions (requires root)."
        exit 1
    fi

    local count=0
    while IFS='|' read -r mac ip vendor; do
        mac="$(echo "$mac" | tr '[:lower:]' '[:upper:]')"
        if ! is_known_host "$mac" "$ip"; then
            echo "${mac}|${ip}|${vendor}" >> "$KNOWN_HOSTS_FILE"
            log "  Added: ${mac} | ${ip} | ${vendor}"
            count=$((count + 1))
        else
            log "  Already known: ${mac} | ${ip}"
        fi
    done <<< "$scan_results"

    log "Added ${count} new hosts. Total known: $(grep -cvE '^\s*(#|$)' "$KNOWN_HOSTS_FILE" 2>/dev/null || echo 0)"
}

# ─── Show mode ──────────────────────────────────────────────────────────────

do_show() {
    echo "=== Known hosts (${KNOWN_HOSTS_FILE}) ==="
    echo ""
    printf "%-20s %-18s %s\n" "MAC" "IP" "DESCRIPTION"
    printf "%-20s %-18s %s\n" "---" "--" "-----------"

    while IFS='|' read -r mac ip desc; do
        [[ "$mac" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$mac" ]] && continue
        printf "%-20s %-18s %s\n" "$mac" "$ip" "$desc"
    done < "$KNOWN_HOSTS_FILE"

    echo ""
    echo "=== Recently seen unknown hosts (${SEEN_UNKNOWN_FILE}) ==="
    echo ""
    if [[ -s "$SEEN_UNKNOWN_FILE" ]]; then
        while IFS='|' read -r mac ts ip; do
            [[ -z "$mac" ]] && continue
            printf "  %s | %s | last alert: %s\n" "$mac" "$ip" "$(date -d @"$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")"
        done < "$SEEN_UNKNOWN_FILE"
    else
        echo "  (none)"
    fi
}

# ─── Main scan mode — scan and alert ───────────────────────────────────────

do_scan() {
    local dry_run="${1:-false}"

    log "Scanning network on interface ${INTERFACE}..."

    local scan_results=""
    scan_results="$(scan_network)" || true

    if [[ -z "$scan_results" ]]; then
        log "No scan results (empty network or interface problem)."
        return
    fi

    local total=0
    local unknown=0

    while IFS='|' read -r mac ip vendor; do
        total=$((total + 1))
        mac="$(echo "$mac" | tr '[:lower:]' '[:upper:]')"

        if ! is_known_host "$mac" "$ip"; then
            unknown=$((unknown + 1))
            log "UNKNOWN HOST: MAC=${mac} IP=${ip} Vendor=${vendor}"

            if [[ "$dry_run" == "true" ]]; then
                log "(dry-run) Skipped sending alert."
            elif already_alerted "$mac" "$ip"; then
                log "Alert for ${mac} (${ip}) already sent within last ${REALERT_HOURS}h — skipping."
            else
                send_alert "$mac" "$ip" "$vendor"
                mark_alerted "$mac" "$ip"
            fi
        fi
    done <<< "$scan_results"

    log "Scan complete. Hosts: ${total} total, ${unknown} unknown."

    if [[ "$dry_run" == "true" ]]; then
        log "Sending test notification..."
        send_test_notification || true
    fi
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

check_deps
init_dirs

case "${1:-}" in
    --learn)
        do_learn
        ;;
    --show)
        do_show
        ;;
    --dry-run)
        do_scan true
        ;;
    --test)
        send_test_notification
        ;;
    --help|-h)
        head -25 "$0" | grep '^#' | sed 's/^# \?//'
        ;;
    *)
        do_scan false
        ;;
esac
