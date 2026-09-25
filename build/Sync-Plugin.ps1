<#
.SYNOPSIS
    Mirrors the plugin project from a nopCommerce source tree into this repository.

.DESCRIPTION
    nopCommerce_4.90.8_Source\src\Plugins\Nop.Plugin.Misc.BlogPostCreated is the canonical
    copy: that is where the plugin is edited and run against the store. This repository is
    the distribution/CI home, so it holds a mirror of the same project.

    Run this after editing in the nopCommerce tree, then review and commit the changes.
    Build output folders (obj, bin) and machine specific files are never copied.

.PARAMETER NopCommerceSrc
    Path to the nopCommerce source tree (the folder that contains 'src' and 'global.json').

.EXAMPLE
    pwsh ./build/Sync-Plugin.ps1 -NopCommerceSrc D:\PROJECTS\miscNopCommerce\nopCommerce_4.90.8_Source
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$NopCommerceSrc,

    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot     = Split-Path -Parent $PSScriptRoot
$assemblyName = 'Nop.Plugin.Misc.BlogPostCreated'
$source       = Join-Path $NopCommerceSrc "src\Plugins\$assemblyName"
$destination  = Join-Path $repoRoot $assemblyName

if (-not (Test-Path -LiteralPath $source)) { throw "plugin not found in nopCommerce tree: $source" }

$excludeDirs = @('obj', 'bin', '.vs', '.git', 'PublishProfiles')
$excludeExts = @('.user', '.pubxml')

$files = Get-ChildItem -LiteralPath $source -Recurse -File -Force | Where-Object {
    # segment based so it works for both '\' and '/' separated paths
    $relative = $_.FullName.Substring($source.Length).TrimStart('\', '/')
    $segments = @(($relative -replace '\\', '/').Split('/') | Where-Object { $_ })
    -not ($segments | Where-Object { $excludeDirs -contains $_ }) -and
    -not ($excludeExts -contains $_.Extension)
}

function Get-RelativeSegments {
    param([string]$Root, [string]$FullName)
    @(($FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/').Split('/') | Where-Object { $_ })
}

$changed = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]

foreach ($file in $files) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    $target = Join-Path $destination $relative
    $state = if (-not (Test-Path -LiteralPath $target)) { 'new' }
             elseif ((Get-FileHash -LiteralPath $file.FullName -Algorithm MD5).Hash -ne
                     (Get-FileHash -LiteralPath $target -Algorithm MD5).Hash) { 'changed' }
             else { 'same' }

    if ($state -eq 'same') { continue }
    $changed.Add("$state  $relative")
    if ($Check) { continue }
    if ($PSCmdlet.ShouldProcess($target, 'sync from nopCommerce tree')) {
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

# files that live only in the repo copy
foreach ($file in (Get-ChildItem -LiteralPath $destination -Recurse -File -Force | Where-Object {
    $relative = $_.FullName.Substring($destination.Length).TrimStart('\', '/')
    $segments = @(($relative -replace '\\', '/').Split('/') | Where-Object { $_ })
    -not ($segments | Where-Object { $excludeDirs -contains $_ })
})) {    $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/')
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) { $missing.Add($relative) }
}

Write-Host "source      : $source" -ForegroundColor Cyan
Write-Host "destination : $destination" -ForegroundColor Cyan
Write-Host ''

if ($changed.Count -eq 0 -and $missing.Count -eq 0) {
    Write-Host 'in sync - nothing to do' -ForegroundColor Green
    exit 0
}

if ($changed.Count) {
    Write-Host "changed ($($changed.Count)):" -ForegroundColor Yellow
    $changed | ForEach-Object { Write-Host "  $_" }
}
if ($missing.Count) {
    Write-Host "only in repo ($($missing.Count)):" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" }
}

if ($Check) { exit 1 }
Write-Host ''
Write-Host 'review the changes, then commit' -ForegroundColor Cyan
exit 0
