BeforeAll {
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-network-ab.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
    $first = Join-Path $fixtures 'A.json'
    $second = Join-Path $fixtures 'B.json'
    $observations = Join-Path $fixtures 'B-observations.json'
}

Describe 'compare' {
    It 'prints the verdict first and includes the human table' {
        $lines = & $script compare $first $second
        $lines[0] | Should -BeExactly 'B: target loss 0% -> 10%, target RTT 8 -> 32 ms, target jitter 2 -> 13 ms, first divergent hop 3, Tailscale direct -> relay (DERP sin)'
        $lines[1] | Should -Match 'Gateway ping'
    }

    It 'produces JSON and skips a hop that answered on only one side' {
        $result = & $script compare $first $second -Json | ConvertFrom-Json
        $result.SameTargetAddress | Should -BeTrue
        $result.FirstDivergentHop | Should -Be 3
        $result.Thresholds.LossPp | Should -Be 10
        $result.B.Ping.Target.LossPct | Should -Be 10
        $result.B.Tailscale.DerpRegion | Should -BeExactly 'sin'
    }

    It 'reports no change when both captures match' {
        $result = & $script compare $first $first -Json | ConvertFrom-Json
        $result.Verdict | Should -BeExactly 'A: no change above thresholds in comparable observations'
        $result.FirstDivergentHop | Should -BeNullOrEmpty
    }

    It 'reports adapter increases, DNS at the threshold, and only events after A' {
        $result = & $script compare $first $observations -Json | ConvertFrom-Json
        $result.Verdict | Should -BeExactly 'B: target adapter (Tailscale) RX errors +2 / TX errors +3 / RX discards +5 / TX discards +7, gateway adapter (Wi-Fi) TX discards +4, target DNS 4.1 -> 29.1 ms, Tcpip 4199 events after A: 1'
        $result.Thresholds.DnsMs | Should -Be 25
    }

    It 'compares only matching adapter counters with values on both sides and a positive delta' {
        $record = Get-Content -LiteralPath $first -Raw | ConvertFrom-Json
        $record.TargetAdapter.RxErrors = 1
        $record.TargetAdapter.TxErrors = $null
        $record.TargetAdapter.RxDiscards = 100
        $record.TargetAdapter.TxDiscards = 7
        $record.GatewayAdapter.InterfaceIndex = 9
        $baseline = Join-Path $TestDrive 'counter-baseline.json'
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baseline -Encoding UTF8
        $result = & $script compare $baseline $observations -Json | ConvertFrom-Json
        $result.Changes | Should -Contain 'target adapter (Tailscale) RX errors +1'
        @($result.Changes | Where-Object { $_ -like '*adapter*' }).Count | Should -Be 1
    }

    It 'reports the same adapter once when it serves both roles' {
        $baseline = Get-Content -LiteralPath $first -Raw | ConvertFrom-Json
        $changed = Get-Content -LiteralPath $observations -Raw | ConvertFrom-Json
        $baseline.GatewayAdapter = $baseline.TargetAdapter
        $changed.GatewayAdapter = $changed.TargetAdapter
        $singleA = Join-Path $TestDrive 'single-adapter-A.json'
        $singleB = Join-Path $TestDrive 'single-adapter-B.json'
        $baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $singleA -Encoding UTF8
        $changed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $singleB -Encoding UTF8
        $result = & $script compare $singleA $singleB -Json | ConvertFrom-Json
        @($result.Changes | Where-Object { $_ -like '*adapter*' }).Count | Should -Be 1
        $result.Verdict | Should -Match 'target adapter'
    }

    It 'identifies which capture could not resolve the target hostname' {
        $record = Get-Content -LiteralPath $second -Raw | ConvertFrom-Json
        $record.TargetAddress = $null
        $record.DnsMs = $null
        $record.Ping.Target = $null
        $failed = Join-Path $TestDrive 'dns-failure.json'
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $failed -Encoding UTF8
        $failure = & $script compare $first $failed -Json | ConvertFrom-Json
        $recovery = & $script compare $failed $first -Json | ConvertFrom-Json
        $failure.Changes | Should -Contain 'target DNS failed in B'
        $recovery.Changes | Should -Contain 'target DNS failed in B'
    }

    It 'compares a hostname and its literal address as one destination' {
        $record = Get-Content -LiteralPath $second -Raw | ConvertFrom-Json
        $record.Target = $record.TargetAddress
        $aliasCapture = Join-Path $TestDrive 'alias.json'
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $aliasCapture -Encoding UTF8
        $result = & $script compare $first $aliasCapture -Json | ConvertFrom-Json
        $result.Verdict | Should -Not -Match 'targets differ'
        $result.FirstDivergentHop | Should -Be 3
    }

    It 'does not compare target ping or hops across destination addresses' {
        $record = Get-Content -LiteralPath $second -Raw | ConvertFrom-Json
        $record.TargetAddress = '203.0.113.12'
        $different = Join-Path $TestDrive 'different.json'
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $different -Encoding UTF8
        $result = & $script compare $first $different -Json | ConvertFrom-Json
        $result.Verdict | Should -Match 'resolved target address changed'
        $result.Verdict | Should -Not -Match 'target loss'
        $result.FirstDivergentHop | Should -BeNullOrEmpty
    }

    It 'rejects an invalid IPv4 address before capture' {
        { & $script capture -Label A -Target '999.0.0.1' } | Should -Throw '*Invalid -Target*'
    }

    It 'rejects an invalid LAN hostname before capture' {
        { & $script capture -Label A -LanHost 'pc;example.test' } | Should -Throw '*Invalid -LanHost*'
    }

    It 'names a missing capture in the error' {
        { & $script compare $first 'missing.json' } | Should -Throw "*Cannot read capture 'missing.json'*"
    }
}
