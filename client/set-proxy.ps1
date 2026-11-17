#requires -Version 5.1
<#
.SYNOPSIS
    Points the Windows system proxy at the egress node.

.EXAMPLE
    .\set-proxy.ps1
    .\set-proxy.ps1 -ProxyHost 100.101.102.103 -ProxyPort 1081
#>
[CmdletBinding()]
param(
    [string]$ProxyHost = 'win-runner',
    [int]$ProxyPort = 1081,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$endpoint = "$ProxyHost`:$ProxyPort"
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

Set-ItemProperty -Path $key -Name 'ProxyEnable' -Value 1 -Type DWord
Set-ItemProperty -Path $key -Name 'ProxyServer' -Value $endpoint -Type String
$bypass = 'localhost;127.*;10.*;172.16.*;172.17.*;192.168.*;100.*;<local>'
Set-ItemProperty -Path $key -Name 'ProxyOverride' -Value $bypass -Type String

Add-Type -Namespace WinInet -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@

[void][WinInet.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
[void][WinInet.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)

Write-Host "system proxy -> $endpoint"

if ($Test) {
    try {
        $probe = Invoke-WebRequest -Uri 'https://api.ipify.org?format=json' -Proxy "http://$endpoint" -UseBasicParsing -TimeoutSec 25
        Write-Host "egress IPv4  -> $($probe.Content)"
    } catch {
        Write-Host "proxy test failed: $($_.Exception.Message)"
        Write-Host 'check that the workflow run is still active and Tailscale is connected'
    }
}
