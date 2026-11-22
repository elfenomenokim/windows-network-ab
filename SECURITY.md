# Security

## Supported versions

Security fixes go to the latest release.

## Report a vulnerability

Use **Report a vulnerability** in the repository's GitHub **Security** tab.
Include the version, PowerShell edition and steps using example hosts.
Describe the expected behavior and the effect you observed.

## Scope

Report a probe that changes routes or clears neighbor entries, writes outside
the chosen output directory, or treats an input hostname as a command.
Capture files are local and may contain addresses, adapter names, peer
endpoints, event messages and, with `-ArpProbe`, link-layer addresses.
Redact captures before attaching them to a report.

Use a normal issue for measurement differences and other behavior reports.
