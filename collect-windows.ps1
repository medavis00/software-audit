<#
  collect-windows.ps1 - lists installed software on this Windows PC.

  Usage (from the software-audit folder):
    powershell -ExecutionPolicy Bypass -File .\collect-windows.ps1
    powershell -ExecutionPolicy Bypass -File .\collect-windows.ps1 -IncludeStoreApps

  Writes inventories\<COMPUTERNAME>.json next to this script.
  Reads the same registry keys that "Apps & features" uses, so no admin rights needed.
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'inventories'),
    [switch]$IncludeStoreApps
)

$ErrorActionPreference = 'SilentlyContinue'

$keys = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Source = 'registry-64' },
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'registry-32' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Source = 'registry-user' }
)

$apps = @{}
foreach ($k in $keys) {
    Get-ItemProperty -Path $k.Path | ForEach-Object {
        $name = "$($_.DisplayName)".Trim()
        if (-not $name) { return }
        if ($_.SystemComponent -eq 1) { return }   # hidden from Apps & features
        if ($_.ParentKeyName) { return }           # patches / sub-components
        $ver = "$($_.DisplayVersion)".Trim()
        $id = "$name|$ver"
        if (-not $apps.ContainsKey($id)) {
            $apps[$id] = [ordered]@{
                name      = $name
                version   = $ver
                publisher = "$($_.Publisher)".Trim()
                source    = $k.Source
            }
        }
    }
}

if ($IncludeStoreApps) {
    Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } | ForEach-Object {
        $id = "$($_.Name)|$($_.Version)"
        if (-not $apps.ContainsKey($id)) {
            $apps[$id] = [ordered]@{
                name      = $_.Name
                version   = "$($_.Version)"
                publisher = $_.PublisherId
                source    = 'store'
            }
        }
    }
}

$os = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    hostname     = $env:COMPUTERNAME
    os           = "$($os.Caption) $($os.Version)".Trim()
    platform     = 'windows'
    collected_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    apps         = @($apps.Values | Sort-Object { $_.name })
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outFile = Join-Path $OutDir "$($env:COMPUTERNAME).json"
$json = $report | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Found $($report.apps.Count) apps. Saved to $outFile"
