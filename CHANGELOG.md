# Changelog

## [Unreleased]

### Added

- Capture named Windows network snapshots as JSON and compare them with a verdict, a table or JSON.
- Record the target route, its effective metric, adapter counters, ICMP loss and timing, trace hops, DNS timing, the target's Tailscale path and recent TCP/IP address-conflict events.
- Report increases in matching adapter counters, changes in DNS resolution, and duplicate-address events after capture A.
- Sample the gateway neighbor entry on request. Capture leaves ARP entries in place.
- Exercise comparison against synthetic fixtures in Windows PowerShell 5.1 and PowerShell 7 on Windows CI.
