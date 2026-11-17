#requires -Version 5.1
<#
.SYNOPSIS
    Clears the Windows system proxy.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

Set-ItemProperty -Path $key -Name 'ProxyEnable' -Value 0 -Type DWord

Add-Type -Namespace WinInet -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
'@

[void][WinInet.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
[void][WinInet.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)

Write-Host 'system proxy cleared'
