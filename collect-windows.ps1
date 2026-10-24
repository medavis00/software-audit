<#
  collect-windows.ps1 - lists installed software on this Windows PC.

  Usage (from the software-audit folder):
    powershell -ExecutionPolicy Bypass -File .\collect-windows.ps1
    powershell -ExecutionPolicy Bypass -File .\collect-windows.ps1 -SkipStoreApps

  Writes inventories\<COMPUTERNAME>.json next to this script.
  Reads the same registry keys that "Apps & features" uses, so no admin rights needed.

  Besides installed apps it records a few extra items, each named with a prefix
  so approved-apps.csv can check them:
    winget                     winget's own version
    vscode-ext:<id>            each VS Code extension
    vs-workload:<id>           each Visual Studio workload
    git-config:<key>           each global git setting (the "version" is its value)
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'inventories'),
    [switch]$SkipStoreApps
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

function Add-Found($name, $version, $publisher, $source) {
    $id = "$name|$version"
    if ($name -and -not $apps.ContainsKey($id)) {
        $apps[$id] = [ordered]@{ name = $name; version = "$version"; publisher = $publisher; source = $source }
    }
}

# Store apps (Windows Terminal, ChatGPT, and others that never appear in the registry)
if (-not $SkipStoreApps) {
    Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } | ForEach-Object {
        Add-Found $_.Name $_.Version $_.PublisherId 'store'
    }
}

if (Get-Command winget -ErrorAction SilentlyContinue) {
    Add-Found 'winget' ("$(winget --version)".Trim() -replace '^v', '') 'Microsoft' 'check'
}

if (Get-Command code -ErrorAction SilentlyContinue) {
    & code --list-extensions --show-versions 2>$null | ForEach-Object {
        $parts = "$_".Trim() -split '@', 2
        Add-Found "vscode-ext:$($parts[0])" $parts[1] '' 'check'
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $instances = & $vswhere -all -prerelease -products * -include packages -format json | Out-String | ConvertFrom-Json
    foreach ($inst in @($instances)) {
        foreach ($pkg in @($inst.packages)) {
            if ($pkg.type -eq 'Workload') { Add-Found "vs-workload:$($pkg.id)" $pkg.version $inst.displayName 'check' }
        }
    }
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    & git config --global --list 2>$null | ForEach-Object {
        $parts = "$_" -split '=', 2
        Add-Found "git-config:$($parts[0])" $parts[1] '' 'check'
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
