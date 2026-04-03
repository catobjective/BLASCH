# BLASCH - Bash Lightweight Automated Script Controlling Hosts
A lightweight Bash script that detects unauthorized devices on a network segment using ARP scanning. When an unknown MAC address appears, it sends a Discord alert with device details.
Built for environments where the set of connected hosts is known and stable — server rooms, DMZs, isolated VLANs, OT/SCADA networks, or any segment where a new device showing up is a security event, not a Tuesday.

## How it works

1. Runs `arp-scan` against a configured subnet
2. Compares every discovered MAC address against a known hosts list
3. If an unknown MAC is found, sends a Discord webhook notification
4. Tracks already-reported hosts to avoid alert spam (configurable cooldown)
5. If a known unknown host changes its IP address, a new alert is triggered immediately

ARP operates at Layer 2 — every device on the broadcast domain must respond, regardless of firewall rules, disabled ICMP, or OS-level stealth settings. This makes it significantly more reliable than ping-based discovery.

## Requirements

- Debian/Ubuntu (tested on Debian 12)
- `arp-scan` and `curl`
- Root privileges (ARP scanning requires raw socket access)

```bash
apt install arp-scan curl
```

## Installation

```bash
# Clone or copy files
mkdir -p /root/blasch
cp net-monitor.sh net-monitor.conf /root/blasch/
chmod 700 /root/blasch/net-monitor.sh
```

## Configuration

All settings live in `net-monitor.conf` next to the script:

```bash
# Network interface to scan
INTERFACE="ens0"

# Subnet to scan (leave empty for arp-scan auto-detect)
SUBNET="192.168.1.0/24"

# Discord webhook URL
WEBHOOK_URL="https://discord.com/api/webhooks/your/webhook"

# Known hosts file
KNOWN_HOSTS_FILE="/root/blasch/known_hosts.conf"

# Already reported unknown hosts (anti-spam)
SEEN_UNKNOWN_FILE="/root/blasch/seen_unknown.dat"

# Re-alert interval for the same unknown host (hours)
REALERT_HOURS=1

# Log prefix (visible in syslog)
LOG_PREFIX="[net-monitor]"
```

## Usage

```
sudo ./net-monitor.sh              # scan and alert
sudo ./net-monitor.sh --learn      # auto-populate known hosts from current network
sudo ./net-monitor.sh --dry-run    # scan + send test notification (no real alerts)
sudo ./net-monitor.sh --test       # send test notification only (no scan)
sudo ./net-monitor.sh --show       # display known hosts and recent unknowns
```

### Initial setup

```bash
# 1. Edit configuration
nano /root/blasch/net-monitor.conf

# 2. Test webhook
sudo /root/blasch/net-monitor.sh --test

# 3. Learn current hosts on the network
sudo /root/blasch/net-monitor.sh --learn

# 4. Review what was discovered
sudo /root/blasch/net-monitor.sh --show

# 5. Dry run — scan and send test notification
sudo /root/blasch/net-monitor.sh --dry-run
```

### Cron

```
*/5 * * * * /root/blasch/net-monitor.sh
```

Output goes to stdout, which cron routes to syslog. No log files to manage or rotate.

## Known hosts file

Format: `MAC|IP|description`, one entry per line. Lines starting with `#` are ignored.

```
AA:BB:CC:DD:EE:01|192.168.1.1|Gateway
AA:BB:CC:DD:EE:10|192.168.1.10|Web server
AA:BB:CC:DD:EE:20|192.168.1.20|Database server
```

MAC is the primary identifier — IP is informational. You can populate this file manually or use `--learn` to auto-discover.

## Alert deduplication

When an unknown host is detected, the script records its MAC and IP with a timestamp. Subsequent scans will not re-alert for the same MAC+IP combination until the cooldown period (`REALERT_HOURS`) expires.

An IP address change on the same MAC triggers a new alert immediately — this catches devices that switch addresses, whether through DHCP or manual reconfiguration.

To force re-alerting for all hosts:

```bash
> /root/blasch/seen_unknown.dat
```

To reset a specific MAC:

```bash
sed -i '/AA:BB:CC:DD:EE:FF/d' /root/blasch/seen_unknown.dat
```

## Discord notifications

Alerts arrive as Discord embeds with device IP, MAC, vendor identification, and timestamp. Test notifications are green, alerts are red.

The `WEBHOOK_URL` in the config accepts any Discord webhook URL. Create one in your Discord server under **Server Settings → Integrations → Webhooks**.

## Recommended use cases

- **Server rooms** — fixed inventory of machines, any new device is suspicious
- **DMZ segments** — internet-facing zones where unauthorized hosts are a security incident
- **Isolated VLANs** — management networks, storage networks, backup segments
- **OT/SCADA networks** — industrial environments where device inventory must be strict
- **Lab environments** — detect when someone plugs in an unauthorized device
- **Networks without DHCP** — static-IP segments where you can't rely on DHCP logs for discovery

## Debugging

If the script exits silently or returns no results:

```bash
# Check arp-scan works directly
sudo arp-scan --interface=ens0 192.168.1.0/24

# Run with debug output
NET_MONITOR_DEBUG=1 sudo /root/blasch/net-monitor.sh --dry-run
```

## License

MIT
