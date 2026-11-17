#requires -Version 7.0
<#
.SYNOPSIS
    Turns an ephemeral windows-2022 GitHub runner into a reachable egress node.

.DESCRIPTION
    Installs Tailscale, joins the tailnet with an auth key, installs sing-box,
    exposes SOCKS5 (1080) and HTTP proxy (1081) bound to the tailnet only,
    optionally enables RDP (3389), then holds the job open until the deadline.

    All inbound ports are restricted to 100.64.0.0/10 (the tailnet range) by
    Windows Firewall, so nothing is reachable from the public internet.

.PARAMETER Minutes
    Runtime budget. Clamped to 1..350 (GitHub kills the job at 360).

.PARAMETER EnableRdp
    Enable Remote Desktop over the tailnet.
#>
[CmdletBinding()]
param(
    [string]$Minutes = $env:RUN_MINUTES,
    [string]$EnableRdp = $env:ENABLE_RDP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TailnetCidr  = '100.64.0.0/10'
$SocksPort    = 1080
$HttpPort     = 1081
$RdpPort      = 3389
$SingBoxDir   = Join-Path $env:RUNNER_TEMP 'sing-box'
$SingBoxExe   = Join-Path $SingBoxDir 'sing-box.exe'
$SingBoxConf  = Join-Path $SingBoxDir 'config.json'
$TailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
$WorkDir      = Join-Path $env:RUNNER_TEMP 'egress'

# ---------------------------------------------------------------- parameters

$runMinutes = 350
if ($Minutes -match '^\d+$') { $runMinutes = [int]$Minutes }
$runMinutes = [Math]::Min([Math]::Max($runMinutes, 1), 350)

$rdpWanted = -not ($EnableRdp -eq 'false' -or $EnableRdp -eq '0')
$hostname  = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { 'win-runner' }

if ([string]::IsNullOrWhiteSpace($env:TS_AUTHKEY)) {
    throw 'Secret TS_AUTHKEY is empty. Add a Tailscale auth key to repository secrets.'
}

New-Item -ItemType Directory -Force -Path $SingBoxDir, $WorkDir | Out-Null
$deadline = (Get-Date).AddMinutes($runMinutes)

function Write-Stage([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

# ------------------------------------------------------------------ tailscale

Write-Stage 'Tailscale'

$msi = Join-Path $WorkDir 'tailscale.msi'
if (-not (Test-Path $TailscaleExe)) {
    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' `
        -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "tailscale MSI failed, exit $($p.ExitCode)" }
    Start-Sleep -Seconds 5
}
if (-not (Test-Path $TailscaleExe)) { throw "tailscale.exe not found at $TailscaleExe" }

Write-Host 'Bringing the node up...'
& $TailscaleExe up --authkey=$($env:TS_AUTHKEY) --hostname=$hostname --accept-dns=false --accept-routes=false
if ($LASTEXITCODE -ne 0) { throw "tailscale up failed, exit $LASTEXITCODE" }

$tsIp = $null
for ($i = 0; $i -lt 30; $i++) {
    $candidate = (& $TailscaleExe ip -4 2>$null | Select-Object -First 1)
    if ($candidate) { $tsIp = $candidate.Trim(); break }
    Start-Sleep -Seconds 4
}
if (-not $tsIp) { throw 'node never received a tailnet address' }

Write-Host "Tailnet address : $tsIp"
Write-Host "DNS name        : $hostname"
& $TailscaleExe status

# ------------------------------------------------------------------- sing-box

Write-Stage 'sing-box'

$pinnedVersion = '1.14.4'
$zipUrl = "https://github.com/SagerNet/sing-box/releases/download/v$pinnedVersion/sing-box-$pinnedVersion-windows-amd64.zip"

$zip = Join-Path $WorkDir 'sing-box.zip'
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
} catch {
    Write-Host "Pinned release unavailable, resolving latest..."
    $rel = Invoke-RestMethod 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -like '*windows-amd64.zip' } | Select-Object -First 1
    if (-not $asset) { throw 'no windows-amd64 asset in the latest sing-box release' }
    $zipUrl = $asset.browser_download_url
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
}

Expand-Archive -Path $zip -DestinationPath $SingBoxDir -Force
$exe = Get-ChildItem -Path $SingBoxDir -Filter 'sing-box.exe' -Recurse | Select-Object -First 1
if (-not $exe) { throw 'sing-box.exe missing from the archive' }
Copy-Item $exe.FullName $SingBoxExe -Force
Write-Host "Binary : $SingBoxExe"
& $SingBoxExe version

$inboundUser = $null
if (-not [string]::IsNullOrWhiteSpace($env:PROXY_USER)) {
    $inboundUser = [ordered]@{
        username = $env:PROXY_USER
        password = $env:PROXY_PASS
    }
}

$socksIn = [ordered]@{
    type        = 'socks'
    tag         = 'socks-in'
    listen      = '0.0.0.0'
    listen_port = $SocksPort
}
$httpIn = [ordered]@{
    type        = 'http'
    tag         = 'http-in'
    listen      = '0.0.0.0'
    listen_port = $HttpPort
}
if ($inboundUser) {
    $socksIn['users'] = @($inboundUser)
    $httpIn['users']  = @($inboundUser)
}

$config = [ordered]@{
    log = [ordered]@{
        level     = 'warn'
        timestamp = $true
    }
    inbounds = @($socksIn, $httpIn)
    outbounds = @(
        [ordered]@{
            type = 'direct'
            tag  = 'direct'
        }
    )
}

$json = $config | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($SingBoxConf, $json, (New-Object System.Text.UTF8Encoding($false)))

& $SingBoxExe check -c $SingBoxConf
if ($LASTEXITCODE -ne 0) { throw 'sing-box rejected the generated config' }

# ------------------------------------------------------------------- firewall

Write-Stage 'firewall'

foreach ($rule in @(
    @{ Name = 'egress-socks'; Port = $SocksPort },
    @{ Name = 'egress-http';  Port = $HttpPort  },
    @{ Name = 'egress-rdp';   Port = $RdpPort   }
)) {
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $rule.Port -RemoteAddress $TailnetCidr | Out-Null
}

foreach ($rule in @('egress-socks', 'egress-http', 'egress-rdp')) {
    Get-NetFirewallRule -DisplayName $rule |
        Select-Object DisplayName, Enabled, Direction, Action |
        Format-Table -AutoSize | Out-String | Write-Host
}

# ------------------------------------------------------------------------ rdp

$rdpPasswordShown = $null
if ($rdpWanted) {
    Write-Stage 'Remote Desktop'

    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name 'fDenyTSConnections' -Value 0 -Type DWord
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'UserAuthentication' -Value 0 -Type DWord
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'SecurityLayer' -Value 0 -Type DWord

    $rdpPassword = $env:RDP_PASSWORD
    if ([string]::IsNullOrWhiteSpace($rdpPassword)) {
        $bytes = New-Object byte[] 18
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $rdpPassword = ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '') + 'Aa9!'
        $rdpPasswordShown = $rdpPassword
    }

    $account = $env:USERNAME
    & net user $account $rdpPassword | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "could not set a password for $account, RDP login will fail" }
    else { Write-Host "RDP account : $account" }

    if ($rdpPasswordShown) {
        Write-Host "RDP password: $rdpPasswordShown" -ForegroundColor Yellow
        Write-Host 'RDP_PASSWORD secret not set, generated one for this run only.'
    }

    Restart-Service TermService -Force -ErrorAction SilentlyContinue
    Write-Host "RDP listening: $((Get-NetTCPConnection -LocalPort $RdpPort -State Listen -ErrorAction SilentlyContinue) -ne $null)"
} else {
    Write-Host 'RDP disabled for this run.'
}

# ---------------------------------------------------------------------- start

Write-Stage 'starting services'

$singBoxLog = Join-Path $WorkDir 'sing-box.log'
$singBoxProc = Start-Process -FilePath $SingBoxExe `
    -ArgumentList 'run', '-c', "`"$SingBoxConf`"" `
    -RedirectStandardError $singBoxLog `
    -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 4
if ($singBoxProc.HasExited) {
    Get-Content $singBoxLog -ErrorAction SilentlyContinue | Write-Host
    throw 'sing-box exited immediately'
}

function Clear-Egress {
    Write-Stage 'teardown'
    if ($singBoxProc -and -not $singBoxProc.HasExited) {
        Stop-Process -Id $singBoxProc.Id -Force -ErrorAction SilentlyContinue
        Write-Host 'sing-box stopped'
    }
    if (Test-Path $TailscaleExe) {
        & $TailscaleExe logout 2>$null | Out-Null
        Write-Host 'tailnet node logged out'
    }
}

try {
    Write-Stage 'ready'

    $directIp = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 20)
    Write-Host "runner public IPv4 : $directIp"
    Write-Host "SOCKS5             : $tsIp`:$SocksPort  (or $hostname`:$SocksPort)"
    Write-Host "HTTP proxy         : $tsIp`:$HttpPort  (or $hostname`:$HttpPort)"
    if ($rdpWanted) { Write-Host "RDP                : $tsIp`:$RdpPort   user $env:USERNAME" }
    Write-Host "deadline           : $($deadline.ToString('u')) ($runMinutes min)"

    while ((Get-Date) -lt $deadline) {
        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        if ($singBoxProc.HasExited) {
            Write-Host "sing-box died, exit code $($singBoxProc.ExitCode)" -ForegroundColor Red
            Get-Content $singBoxLog -Tail 20 -ErrorAction SilentlyContinue | Write-Host
            throw 'proxy process died'
        }

        $egress = try { (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 15).ip }
                  catch { 'unreachable' }
        $stamp = (Get-Date).ToString('HH:mm:ss')
        Write-Host "[$stamp] alive | remaining ${remaining}s | egress $egress | socks $tsIp`:$SocksPort"

        $sleep = [Math]::Min(300, [Math]::Max(15, $remaining))
        Start-Sleep -Seconds $sleep
    }

    Write-Host 'deadline reached, shutting down'
}
finally {
    Clear-Egress
}
