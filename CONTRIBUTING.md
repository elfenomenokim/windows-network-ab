# Contributing

## Before you start

Open an issue for a change that adds a probe or changes the capture format.
Describe the network condition you want to distinguish and the observation
you expect the comparison to report.

For a defect, include the version, PowerShell edition, command and expected
output. Use sample addresses in the example. For security reports, follow
[SECURITY.md](SECURITY.md).

## Setup

Run the tests from the repository directory in Windows PowerShell 5.1 and
PowerShell 7.

```powershell
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path ./tests -CI
```

The tests compare JSON fixtures without sending network traffic.
Use a Windows device for a change that affects capture.

## Patch

Keep the change focused on one behavior. Add a fixture when an existing
fixture does not cover the comparison change. Preserve null measurements
when a probe is unavailable, and keep gateway neighbor sampling read-only.

Update both READMEs and add a changelog line for user-visible changes.
State which PowerShell versions and capture conditions you exercised.

Follow the [code of conduct](CODE_OF_CONDUCT.md) in project discussions.
