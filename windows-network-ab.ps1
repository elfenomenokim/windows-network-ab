#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('capture', 'compare')]
    [string]$Command,

    [Parameter(ParameterSetName = 'Capture')]
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z')]
    [string]$Label,
    [Parameter(ParameterSetName = 'Capture')]
    [string]$Target = '8.8.8.8',
    [Parameter(ParameterSetName = 'Capture')]
    [string]$LanHost,
    [Parameter(ParameterSetName = 'Capture')]
    [string]$Out = '.',
    [Parameter(ParameterSetName = 'Capture')]
    [switch]$ArpProbe,

    [Parameter(ParameterSetName = 'Compare', Position = 1)]
    [string]$First,
    [Parameter(ParameterSetName = 'Compare', Position = 2)]
    [string]$Second,
    [Parameter(ParameterSetName = 'Compare')]
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PingSamples = 10
$PingTimeoutMs = 750
$PingIntervalMs = 200
$TraceMaxHops = 20
$TraceTimeoutMs = 350
$EventHours = 24
$EventLimit = 20
$LossThresholdPp = 10 # One reply out of the default ten-probe sample.
$LatencyThresholdMs = 20 # Tool heuristic for a material change in mean RTT.
$JitterThresholdMs = 10 # Tool heuristic for a material change in mean RTT variation.
$DnsThresholdMs = 25 # Tool heuristic to ignore small variations in resolver timing.

function Test-HostInput {
    param([string]$Name, [string]$Parameter)

    $message = "Invalid -$($Parameter) '$Name'. Use a dotted-decimal IPv4 address or an ASCII hostname."
    if ($Name -match '\A[0-9.]+\z') {
        $address = $null
        if ($Name -notmatch '\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z' -or
            -not [Net.IPAddress]::TryParse($Name, [ref]$address)) {
            throw $message
        }
        return $true
    }
    $hostname = $Name -replace '\.$', ''
    if ($hostname.Length -gt 253 -or
        $hostname -notmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z' -or
        $hostname -match '\A0x[0-9a-f]+\z') {
        throw $message
    }
    return $false
}

function Resolve-ProbeHost {
    param([string]$Name, [bool]$IsAddress)

    if ($IsAddress) {
        return [pscustomobject]@{ Address = $Name; DnsMs = $null; Error = $null }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $addresses = [Net.Dns]::GetHostAddresses($Name)
        $timer.Stop()
        $address = $addresses | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1
        if ($null -eq $address) { throw 'No IPv4 address returned.' }
        [pscustomobject]@{
            Address = $address.IPAddressToString
            DnsMs = [math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            Error = $null
        }
    } catch {
        [pscustomobject]@{ Address = $null; DnsMs = $null; Error = $_.Exception.Message }
    }
}

function Measure-Ping {
    param([string]$Address)

    if (-not $Address) { return }
    $ping = New-Object Net.NetworkInformation.Ping
    $times = @()
    try {
        for ($i = 0; $i -lt $PingSamples; $i++) {
            $reply = $ping.Send([Net.IPAddress]::Parse($Address), $PingTimeoutMs)
            if ($reply.Status -eq 'Success') { $times += $reply.RoundtripTime }
            if ($i -lt $PingSamples - 1) { Start-Sleep -Milliseconds $PingIntervalMs }
        }
    } finally {
        $ping.Dispose()
    }
    $average = $null
    $jitter = $null
    if ($times.Count -gt 0) {
        $average = [math]::Round(($times | Measure-Object -Average).Average, 1)
    }
    if ($times.Count -gt 1) {
        $variation = 0
        for ($i = 1; $i -lt $times.Count; $i++) {
            $variation += [math]::Abs($times[$i] - $times[$i - 1])
        }
        $jitter = [math]::Round($variation / ($times.Count - 1), 1)
    }
    [pscustomobject]@{
        Address = $Address
        Sent = $PingSamples
        Received = $times.Count
        LossPct = [math]::Round(100 * ($PingSamples - $times.Count) / $PingSamples, 1)
        AvgMs = $average
        JitterMs = $jitter
    }
}

function Get-RouteRecord {
    param($Route, $Interface, [string]$SourceAddress)

    if ($null -eq $Route) { return }
    $effective = $null
    if ($null -ne $Interface.InterfaceMetric) {
        $effective = [int]$Route.RouteMetric + [int]$Interface.InterfaceMetric
    }
    [pscustomobject]@{
        InterfaceAlias = $Route.InterfaceAlias
        InterfaceIndex = $Route.InterfaceIndex
        SourceAddress = $SourceAddress
        DestinationPrefix = $Route.DestinationPrefix
        NextHop = $Route.NextHop
        RouteMetric = $Route.RouteMetric
        InterfaceMetric = $Interface.InterfaceMetric
        EffectiveMetric = $effective
    }
}

function Get-AdapterRecord {
    param($Route)

    if ($null -eq $Route) { return }
    try {
        $name = [Management.Automation.WildcardPattern]::Escape($Route.InterfaceAlias)
        $stats = Get-NetAdapterStatistics -Name $name -IncludeHidden
        [pscustomobject]@{
            InterfaceAlias = $Route.InterfaceAlias
            InterfaceIndex = $Route.InterfaceIndex
            RxErrors = $stats.ReceivedPacketErrors
            TxErrors = $stats.OutboundPacketErrors
            RxDiscards = $stats.ReceivedDiscardedPackets
            TxDiscards = $stats.OutboundDiscardedPackets
        }
    } catch {
        $captureErrors.Add("Adapter statistics ($($Route.InterfaceAlias)): $($_.Exception.Message)")
    }
}

function Get-TargetTrace {
    param([string]$Address)

    if (-not $Address) { return }
    # A timeout in any probe column is independent of the final IPv4 address.
    $lines = & tracert.exe -4 -d -h $TraceMaxHops -w $TraceTimeoutMs $Address
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d{1,2})\s+(.+)$') {
            $hop = [int]$Matches[1]
            $address = $null
            if ($Matches[2] -match '(?:^|\s)(\d{1,3}(?:\.\d{1,3}){3})\s*$') {
                $address = $Matches[1]
            }
            [pscustomobject]@{ Hop = $hop; Address = $address }
        }
    }
}

function Get-TailscalePath {
    param([string]$Name, [string]$Address)

    $result = [ordered]@{
        State = 'not-installed'; Peer = $null; PeerAddress = $null
        Mode = $null; Endpoint = $null; DerpRegion = $null
    }
    $cli = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cli) {
        try {
            $raw = & $cli.Source status --json
            if ($LASTEXITCODE -ne 0) { throw "tailscale status --json exited $LASTEXITCODE." }
            $status = $raw | Out-String | ConvertFrom-Json
            $result.State = $status.BackendState
            $peer = $status.Peer.PSObject.Properties.Value | Where-Object {
                ($Address -and $_.TailscaleIPs -contains $Address) -or
                ($_.DNSName -and $_.DNSName.TrimEnd('.') -eq $Name.TrimEnd('.'))
            } | Select-Object -First 1
            if ($peer) {
                $result.Peer = $peer.DNSName
                $result.PeerAddress = $peer.TailscaleIPs | Where-Object { $_ -notmatch ':' } | Select-Object -First 1
                $result.Mode = 'unknown'
                # Match the CLI's active-path precedence. Relay can remain set on a direct peer.
                # Source: https://github.com/tailscale/tailscale/blob/main/cmd/tailscale/cli/status.go
                if ($peer.Active) {
                    if ($peer.CurAddr) {
                        $result.Mode = 'direct'
                        $result.Endpoint = $peer.CurAddr
                    } elseif ($peer.PeerRelay) {
                        $result.Mode = 'peer-relay'
                        $result.Endpoint = $peer.PeerRelay
                    } elseif ($peer.Relay) {
                        $result.Mode = 'derp'
                        $result.DerpRegion = $peer.Relay
                    }
                }
            }
        } catch {
            $result.State = 'unavailable'
            $captureErrors.Add("Tailscale: $($_.Exception.Message)")
        }
    }
    [pscustomobject]$result
}

function Get-ConflictEvents {
    $filter = @{ LogName = 'System'; Id = 4199; StartTime = (Get-Date).AddHours(-$EventHours) }
    try {
        Get-WinEvent -FilterHashtable $filter -MaxEvents $EventLimit |
            Where-Object ProviderName -in @('Tcpip', 'Microsoft-Windows-TCPIP') |
            ForEach-Object {
                [pscustomobject]@{ TimeUtc = $_.TimeCreated.ToUniversalTime().ToString('o'); Message = $_.Message }
            }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound,*') { throw }
    }
}

function Get-ArpSamples {
    param([string]$Gateway, [int]$InterfaceIndex)

    for ($i = 0; $i -lt 3; $i++) {
        $neighbor = Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $InterfaceIndex -IPAddress $Gateway -ErrorAction SilentlyContinue |
            Select-Object -First 1
        [pscustomobject]@{
            TimeUtc = [DateTime]::UtcNow.ToString('o')
            LinkLayerAddress = $neighbor.LinkLayerAddress
            State = [string]$neighbor.State
        }
        if ($i -lt 2) { Start-Sleep -Milliseconds 250 }
    }
}

function Invoke-Capture {
    $targetIsAddress = Test-HostInput $Target 'Target'
    $lanIsAddress = $false
    if ($LanHost) { $lanIsAddress = Test-HostInput $LanHost 'LanHost' }
    if ($env:OS -ne 'Windows_NT') { throw 'Capture requires Windows. Compare can read captures on other platforms.' }

    $captureErrors = New-Object 'System.Collections.Generic.List[string]'
    $started = [DateTime]::UtcNow
    $targetInfo = Resolve-ProbeHost $Target $targetIsAddress
    $lanInfo = $null
    if ($LanHost) { $lanInfo = Resolve-ProbeHost $LanHost $lanIsAddress }
    if ($targetInfo.Error) { $captureErrors.Add("Target DNS ($Target): $($targetInfo.Error)") }
    if ($lanInfo.Error) { $captureErrors.Add("LAN DNS ($LanHost): $($lanInfo.Error)") }

    $interfaces = @{}
    Get-NetIPInterface -AddressFamily IPv4 | ForEach-Object { $interfaces[[int]$_.InterfaceIndex] = $_ }
    $defaultRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $interfaces[[int]$_.InterfaceIndex].ConnectionState -eq 'Connected' } |
        ForEach-Object { Get-RouteRecord $_ $interfaces[[int]$_.InterfaceIndex] } |
        Sort-Object EffectiveMetric, InterfaceIndex | Select-Object -First 1

    $targetRoute = $null
    if ($targetInfo.Address) {
        try {
            # Ask Windows for the real route, including longest prefix and effective metric.
            $selection = Find-NetRoute -RemoteIPAddress $targetInfo.Address
            $route = $selection | Where-Object DestinationPrefix | Select-Object -First 1
            if ($route) {
                $source = $selection | Where-Object IPAddress | Select-Object -First 1
                $targetRoute = Get-RouteRecord $route $interfaces[[int]$route.InterfaceIndex] $source.IPAddress
            }
        } catch {
            $captureErrors.Add("Target route: $($_.Exception.Message)")
        }
    }
    $gatewayRoute = $targetRoute
    if (-not $gatewayRoute.NextHop -or $gatewayRoute.NextHop -eq '0.0.0.0') { $gatewayRoute = $defaultRoute }
    $gateway = $gatewayRoute.NextHop
    if ($gateway -eq '0.0.0.0') { $gateway = $null }

    $targetAdapter = Get-AdapterRecord $targetRoute
    $gatewayAdapter = $targetAdapter
    if ($gatewayRoute.InterfaceIndex -ne $targetRoute.InterfaceIndex) {
        $gatewayAdapter = Get-AdapterRecord $gatewayRoute
    }

    $ping = [ordered]@{ Gateway = $null; Lan = $null; Target = $null }
    $destinations = @{ Gateway = $gateway; Lan = $lanInfo.Address; Target = $targetInfo.Address }
    foreach ($segment in $destinations.Keys) {
        if (-not $destinations[$segment]) { continue }
        try {
            $ping[$segment] = Measure-Ping $destinations[$segment]
        } catch {
            $captureErrors.Add("$segment ping: $($_.Exception.Message)")
        }
    }

    $tailscale = Get-TailscalePath $Target $targetInfo.Address
    $hops = @()
    try {
        $hops = @(Get-TargetTrace $targetInfo.Address)
        if ($targetInfo.Address -and $hops.Count -eq 0) { $captureErrors.Add('Traceroute returned no hop rows.') }
    } catch {
        $captureErrors.Add("Traceroute: $($_.Exception.Message)")
    }

    $events = $null
    try {
        $events = @(Get-ConflictEvents)
    } catch {
        $captureErrors.Add("Tcpip 4199: $($_.Exception.Message)")
    }
    $arp = $null
    if ($ArpProbe -and $gateway) {
        $arp = @(Get-ArpSamples $gateway $gatewayRoute.InterfaceIndex)
    }
    $capture = [ordered]@{
        SchemaVersion = 1
        Label = $Label
        CapturedUtc = $started.ToString('o')
        Computer = $env:COMPUTERNAME
        Target = $Target
        TargetAddress = $targetInfo.Address
        LanHost = $LanHost
        DnsMs = $targetInfo.DnsMs
        TargetRoute = $targetRoute
        DefaultRoute = $defaultRoute
        TargetAdapter = $targetAdapter
        GatewayAdapter = $gatewayAdapter
        Ping = $ping
        Hops = $hops
        Tailscale = $tailscale
        Tcpip4199 = $events
        ArpSamples = $arp
        Errors = $captureErrors.ToArray()
    }
    $dir = New-Item -ItemType Directory -Path $Out -Force
    $file = Join-Path $dir.FullName "$Label.json"
    $capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Output "Saved $Label.json"
}

function Read-Capture {
    param([string]$Path)

    try {
        $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.SchemaVersion -ne 1 -or $record.Label -notmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z' -or
            -not $record.Target -or -not $record.Ping -or -not $record.Tailscale) {
            throw 'Expected a windows-network-ab capture with schema version 1.'
        }
        return $record
    } catch {
        throw "Cannot read capture '$Path': $($_.Exception.Message)"
    }
}

function Format-PingReading {
    param($Reading)

    if (-not $Reading.Sent) { return 'unavailable' }
    $average = if ($null -eq $Reading.AvgMs) { '-' } else { $Reading.AvgMs }
    $jitter = if ($null -eq $Reading.JitterMs) { '-' } else { $Reading.JitterMs }
    "$($Reading.LossPct)% loss, $average ms RTT, $jitter ms jitter"
}

function Format-RouteReading {
    param($Route)

    if ($null -eq $Route) { return 'unavailable' }
    "$($Route.InterfaceAlias), $($Route.DestinationPrefix) via $($Route.NextHop), cost $($Route.EffectiveMetric)"
}

function Format-PathReading {
    param($Path)

    switch ($Path.Mode) {
        'direct' { 'direct' }
        'derp' { "relay (DERP $($Path.DerpRegion))" }
        'peer-relay' { 'peer relay' }
        'unknown' { 'peer path unknown' }
        default { if ($Path.State -eq 'Running') { 'no matching peer' } else { $Path.State } }
    }
}

function Format-AdapterReading {
    param($Adapter)

    if ($null -eq $Adapter) { return 'unavailable' }
    "$($Adapter.RxErrors)/$($Adapter.TxErrors) errors, $($Adapter.RxDiscards)/$($Adapter.TxDiscards) discards"
}

function Compare-PingReading {
    param([string]$Segment, $A, $B)

    if (-not $A.Sent -or -not $B.Sent) { return }
    if ([math]::Abs($B.LossPct - $A.LossPct) -ge $LossThresholdPp) {
        "$Segment loss $($A.LossPct)% -> $($B.LossPct)%"
    }
    if ($null -ne $A.AvgMs -and $null -ne $B.AvgMs -and
        [math]::Abs($B.AvgMs - $A.AvgMs) -ge $LatencyThresholdMs) {
        "$Segment RTT $($A.AvgMs) -> $($B.AvgMs) ms"
    }
    if ($null -ne $A.JitterMs -and $null -ne $B.JitterMs -and
        [math]::Abs($B.JitterMs - $A.JitterMs) -ge $JitterThresholdMs) {
        "$Segment jitter $($A.JitterMs) -> $($B.JitterMs) ms"
    }
}

function Test-SameAdapter {
    param($A, $B)

    return $A.InterfaceAlias -and $null -ne $A.InterfaceIndex -and
        $A.InterfaceAlias -eq $B.InterfaceAlias -and $A.InterfaceIndex -eq $B.InterfaceIndex
}

function Compare-AdapterReading {
    param([string]$Segment, $A, $B)

    if (-not (Test-SameAdapter $A $B)) { return }
    $counters = [ordered]@{
        RxErrors = 'RX errors'
        TxErrors = 'TX errors'
        RxDiscards = 'RX discards'
        TxDiscards = 'TX discards'
    }
    $increases = foreach ($counter in $counters.Keys) {
        if ($null -eq $A.$counter -or $null -eq $B.$counter) { continue }
        $delta = [decimal]$B.$counter - [decimal]$A.$counter
        if ($delta -gt 0) { "$($counters[$counter]) +$delta" }
    }
    if ($increases) { "$Segment adapter ($($B.InterfaceAlias)) $($increases -join ' / ')" }
}

function Find-DivergentHop {
    param($A, $B)

    $observed = @{}
    foreach ($hop in $A) {
        if ($hop.Address) { $observed[[int]$hop.Hop] = $hop.Address }
    }
    foreach ($hop in ($B | Sort-Object Hop)) {
        $index = [int]$hop.Hop
        if ($hop.Address -and $observed.ContainsKey($index) -and $observed[$index] -ne $hop.Address) {
            return $index
        }
    }
}

function Test-RouteChanged {
    param($A, $B)

    foreach ($property in @('InterfaceAlias', 'InterfaceIndex', 'SourceAddress', 'DestinationPrefix', 'NextHop', 'RouteMetric', 'InterfaceMetric')) {
        if ($A.$property -ne $B.$property) { return $true }
    }
    return $false
}

function Compare-Captures {
    param($A, $B)

    $changes = New-Object 'System.Collections.Generic.List[string]'
    $sameTarget = $A.Target.TrimEnd('.') -eq $B.Target.TrimEnd('.')
    $sameAddress = $A.TargetAddress -and $A.TargetAddress -eq $B.TargetAddress
    $sameLanAddress = $A.Ping.Lan.Address -and $A.Ping.Lan.Address -eq $B.Ping.Lan.Address
    $divergent = $null

    if (-not $sameTarget -and -not $sameAddress) {
        $changes.Add("targets differ ($($A.Target) -> $($B.Target))")
    } elseif (-not $sameAddress) {
        if ($A.TargetAddress -and $B.TargetAddress) { $changes.Add('resolved target address changed') }
        else { $changes.Add('target address unavailable in one or both captures') }
    }
    if ($sameAddress) {
        if ($A.Ping.Target.Sent -and $B.Ping.Target.Sent) {
            Compare-PingReading 'target' $A.Ping.Target $B.Ping.Target | ForEach-Object { $changes.Add($_) }
        } else {
            $changes.Add('target ping unavailable in one or both captures')
        }
        $divergent = Find-DivergentHop $A.Hops $B.Hops
        if ($null -ne $divergent) { $changes.Add("first divergent hop $divergent") }
    }
    Compare-PingReading 'gateway' $A.Ping.Gateway $B.Ping.Gateway | ForEach-Object { $changes.Add($_) }
    if ($sameLanAddress) {
        Compare-PingReading 'LAN' $A.Ping.Lan $B.Ping.Lan | ForEach-Object { $changes.Add($_) }
    }

    $pathA = Format-PathReading $A.Tailscale
    $pathB = Format-PathReading $B.Tailscale
    if ($pathA -ne $pathB) {
        $changes.Add("Tailscale $pathA -> $pathB")
    } elseif ($B.Tailscale.Endpoint -and $A.Tailscale.Endpoint -and $A.Tailscale.Endpoint -ne $B.Tailscale.Endpoint) {
        $changes.Add("Tailscale $pathB endpoint changed")
    }
    if (Test-RouteChanged $A.TargetRoute $B.TargetRoute) { $changes.Add('target route changed') }
    if (Test-RouteChanged $A.DefaultRoute $B.DefaultRoute) { $changes.Add('default route changed') }

    if ($A.Computer -eq $B.Computer) {
        Compare-AdapterReading 'target' $A.TargetAdapter $B.TargetAdapter | ForEach-Object { $changes.Add($_) }
        if (-not (Test-SameAdapter $A.TargetAdapter $A.GatewayAdapter) -or
            -not (Test-SameAdapter $B.TargetAdapter $B.GatewayAdapter)) {
            Compare-AdapterReading 'gateway' $A.GatewayAdapter $B.GatewayAdapter | ForEach-Object { $changes.Add($_) }
        }
    }

    if ($null -ne $A.DnsMs -and -not $B.TargetAddress) {
        $changes.Add("target DNS failed in $($B.Label)")
    } elseif ($null -ne $B.DnsMs -and -not $A.TargetAddress) {
        $changes.Add("target DNS failed in $($A.Label)")
    } elseif ($sameTarget -and $null -ne $A.DnsMs -and $null -ne $B.DnsMs -and
        [math]::Abs([decimal]$B.DnsMs - [decimal]$A.DnsMs) -ge $DnsThresholdMs) {
        $changes.Add("target DNS $($A.DnsMs) -> $($B.DnsMs) ms")
    }

    if ($A.CapturedUtc -and $B.Tcpip4199) {
        $after = [DateTimeOffset]$A.CapturedUtc
        $newConflicts = @($B.Tcpip4199 | Where-Object { $_.TimeUtc -and [DateTimeOffset]$_.TimeUtc -gt $after }).Count
        if ($newConflicts -gt 0) { $changes.Add("Tcpip 4199 events after $($A.Label): $newConflicts") }
    }

    $usablePing = ($sameAddress -and $A.Ping.Target.Sent -and $B.Ping.Target.Sent) -or
        ($A.Ping.Gateway.Sent -and $B.Ping.Gateway.Sent) -or $sameLanAddress
    if ($changes.Count -eq 0) {
        if ($usablePing) { $changes.Add('no change above thresholds in comparable observations') }
        else { $changes.Add('insufficient comparable measurements') }
    }

    $verdict = "$($B.Label): $($changes -join ', ')"
    if ($Json) {
        [ordered]@{
            SchemaVersion = 1
            Verdict = $verdict
            Changes = $changes.ToArray()
            SameTargetAddress = [bool]$sameAddress
            FirstDivergentHop = $divergent
            Thresholds = @{ LossPp = $LossThresholdPp; AvgMs = $LatencyThresholdMs; JitterMs = $JitterThresholdMs; DnsMs = $DnsThresholdMs }
            A = $A
            B = $B
        } | ConvertTo-Json -Depth 12
        return
    }

    $rows = @(
        [pscustomobject]@{ Observation = 'Target'; A = $A.TargetAddress; B = $B.TargetAddress }
        [pscustomobject]@{ Observation = 'Target ping'; A = (Format-PingReading $A.Ping.Target); B = (Format-PingReading $B.Ping.Target) }
        [pscustomobject]@{ Observation = 'Gateway ping'; A = (Format-PingReading $A.Ping.Gateway); B = (Format-PingReading $B.Ping.Gateway) }
        [pscustomobject]@{ Observation = 'LAN ping'; A = (Format-PingReading $A.Ping.Lan); B = (Format-PingReading $B.Ping.Lan) }
        [pscustomobject]@{ Observation = 'Target route'; A = (Format-RouteReading $A.TargetRoute); B = (Format-RouteReading $B.TargetRoute) }
        [pscustomobject]@{ Observation = 'Default route'; A = (Format-RouteReading $A.DefaultRoute); B = (Format-RouteReading $B.DefaultRoute) }
        [pscustomobject]@{ Observation = 'Tailscale'; A = $pathA; B = $pathB }
        [pscustomobject]@{ Observation = 'DNS (ms)'; A = $A.DnsMs; B = $B.DnsMs }
        [pscustomobject]@{ Observation = 'Target adapter RX/TX'; A = (Format-AdapterReading $A.TargetAdapter); B = (Format-AdapterReading $B.TargetAdapter) }
        [pscustomobject]@{ Observation = 'Gateway adapter RX/TX'; A = (Format-AdapterReading $A.GatewayAdapter); B = (Format-AdapterReading $B.GatewayAdapter) }
        [pscustomobject]@{
            Observation = 'Tcpip 4199'
            A = if ($null -ne $A.Tcpip4199) { $A.Tcpip4199.Count } else { 'unavailable' }
            B = if ($null -ne $B.Tcpip4199) { $B.Tcpip4199.Count } else { 'unavailable' }
        }
    )
    Write-Output $verdict
    $columns = 'Observation', @{ Label = $A.Label; Expression = 'A' }, @{ Label = $B.Label; Expression = 'B' }
    $rows | Format-Table -Property $columns -AutoSize | Out-String -Width 180
}

if ($Command -eq 'compare') {
    if (-not $First -or -not $Second) { throw 'Usage: compare A.json B.json [-Json]' }
    Compare-Captures (Read-Capture $First) (Read-Capture $Second)
} else {
    if (-not $Label -or $PSCmdlet.ParameterSetName -ne 'Capture') {
        throw 'Usage: capture -Label A [-Target host] [-LanHost host] [-Out directory] [-ArpProbe]'
    }
    if ($PSBoundParameters.ContainsKey('LanHost') -and -not $LanHost) {
        throw 'Invalid -LanHost. Use a dotted-decimal IPv4 address or an ASCII hostname.'
    }
    Invoke-Capture
}
