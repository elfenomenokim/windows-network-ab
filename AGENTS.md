## Set up for a user

1. Run `$env:OS; $PSVersionTable.PSVersion` on the Windows PC that will take
   the captures. Expect `Windows_NT` and PowerShell 5.1 or 7.
   `Get-Command Find-NetRoute, Get-NetAdapterStatistics, Get-WinEvent, tracert.exe`
   should list all four commands. `Get-Command tailscale.exe -ErrorAction SilentlyContinue`
   is optional and only needed for peer path data.
2. Create a folder in the user's profile and fetch the script.

   ```powershell
   $dir = New-Item -ItemType Directory -Path "$HOME\windows-network-ab" -Force
   $script = Join-Path $dir.FullName 'windows-network-ab.ps1'
   Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/elfenomenokim/windows-network-ab/main/windows-network-ab.ps1' -OutFile $script
   Unblock-File -LiteralPath $script
   Set-Location -LiteralPath $dir.FullName
   ```

   If GitHub returns 404 before publication, copy `windows-network-ab.ps1`
   from this checkout to `$script`. Capture uses a normal Windows account.
3. Prove the local path with one address in both captures.

   ```powershell
   .\windows-network-ab.ps1 capture -Label A -Target localhost
   .\windows-network-ab.ps1 capture -Label B -Target localhost
   .\windows-network-ab.ps1 compare .\A.json .\B.json
   ```

   Expect `Saved A.json` and `Saved B.json`, followed by a line beginning
   `B: ` and a table.
4. Only the person needs to identify an unknown target or change a physical
   connection. For remote-screen diagnosis, ask if needed, “What hostname or
   IPv4 address does the remote-screen client connect to?” Before a comparison
   that requires a cable or Wi-Fi change, say, “Tell me when the second
   connection is ready so I can run capture B.” Use the same target both times.
5. If it fails, check these in order.

   - If script execution is restricted, run the command in a process launched
     with `powershell.exe -ExecutionPolicy Bypass -File .\windows-network-ab.ps1`
     or `pwsh.exe -ExecutionPolicy Bypass -File .\windows-network-ab.ps1`,
     followed by the capture or compare arguments. Leave device policy alone.
   - For an invalid target, pass a dotted-decimal IPv4 address or an ASCII
     hostname. For a valid name that fails to resolve, read `Errors` in the
     capture and check the configured resolver or MagicDNS.
   - For a peer path marked unknown, send traffic to the same peer and capture
     again while the connection is active.

## Working in the repo

- `windows-network-ab.ps1` contains the CLI and versioned capture format.
- `tests/fixtures` has synthetic addresses and paths. The compare tests run
  without a network.
- From the repo root, run `Import-Module Pester -RequiredVersion 5.7.1` and
  `Invoke-Pester -Path ./tests -CI` in PowerShell 5.1 and 7.
- The static demo is the output of `./windows-network-ab.ps1 compare tests/fixtures/A.json tests/fixtures/B.json`. Use Freeze to render updated light and dark copies.
- Keep capture compatible with Windows PowerShell 5.1. Use the Windows route
  selected for the target and retain the component metrics.
- ARP sampling is opt-in. Use read-only neighbor lookups. Use synthetic
  addresses in fixtures, examples and demos.
- Update both READMEs and the changelog when CLI output changes.
