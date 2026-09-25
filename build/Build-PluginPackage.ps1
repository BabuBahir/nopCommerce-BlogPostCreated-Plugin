<#
.SYNOPSIS
    Builds the plugin against a nopCommerce source tree and produces an uploadable
    nopCommerce plugin package (.zip).

.DESCRIPTION
    One entry point used both locally and in CI (.github/workflows/package-plugin.yml).
    It deliberately avoids Compress-Archive: Windows PowerShell 5.1 writes backslash
    separated entry names into the archive, and nopCommerce matches entry.FullName against
    forward-slash literals (UploadService.UploadSingleItemAsync and
    UploadMultipleItemsAsync). A backslash archive uploads "0 plugins and 0 themes".

    Steps: build -> ref-assembly guard -> whitelist-collect -> version assert -> zip -> verify.

    The verification pass replays the nopCommerce upload logic against the finished archive,
    so anything that would make the admin report zero plugins fails the build.

.PARAMETER NopCommerceSrc
    Path to the nopCommerce source tree (the folder that contains 'src' and 'global.json').

.PARAMETER NopCommerceVersion
    nopCommerce version this package targets, e.g. 4.90. Asserted to be present in both
    plugin.json SupportedVersions and uploadedItems.json so a version bump cannot silently
    desynchronise them.

.PARAMETER Configuration
    Build configuration. Defaults to Release.

.PARAMETER PluginProject
    Path to the plugin csproj. Defaults to the copy shipped in this repository.

.PARAMETER OutputZip
    Where to write the package. Defaults to ../Plugin.BlogNotifier.zip next to the repo.

.PARAMETER SkipBuild
    Package whatever is already in the nopCommerce build output folder.

.PARAMETER VerifyOnly
    Skip build, collect and zip; only run the verification pass over -OutputZip. Useful to
    re-check an artifact produced elsewhere.

.EXAMPLE
    pwsh ./build/Build-PluginPackage.ps1 -NopCommerceSrc D:\PROJECTS\miscNopCommerce\nopCommerce_4.90.8_Source

.EXAMPLE
    ./build/Build-PluginPackage.ps1 -NopCommerceSrc ../nopCommerce -VerifyOnly -OutputZip ./out/Plugin.BlogNotifier.zip
#>
[CmdletBinding()]
param(
    [string]$NopCommerceSrc,

    [string]$NopCommerceVersion = '4.90',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$PluginProject,

    [string]$OutputZip,

    [switch]$SkipBuild,

    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot           = Split-Path -Parent $PSScriptRoot
$pluginSystemName   = 'Misc.BlogPostCreated'
$pluginAssemblyName = 'Nop.Plugin.Misc.BlogPostCreated'
$versionDir         = "BlogPostCreated/nopCommerce-$NopCommerceVersion"

if (-not $PluginProject) { $PluginProject = Join-Path $repoRoot "$pluginAssemblyName\$pluginAssemblyName.csproj" }
if (-not $OutputZip)      { $OutputZip      = Join-Path (Split-Path -Parent $repoRoot) 'Plugin.BlogNotifier.zip' }

$projectRoot   = Split-Path -Parent $PluginProject

if (-not $VerifyOnly) {
    if (-not $NopCommerceSrc) { Fail '-NopCommerceSrc is required unless -VerifyOnly is used' }
    $solutionDir   = Join-Path $NopCommerceSrc 'src'
    $nopWebProject = Join-Path $solutionDir 'Presentation\Nop.Web\Nop.Web.csproj'
    $clearProj     = Join-Path $solutionDir 'Build\ClearPluginAssemblies.proj'
    $buildOutput   = Join-Path $solutionDir "Presentation\Nop.Web\Plugins\$pluginSystemName"
}

$binaryZipDir = "$versionDir/$pluginSystemName"
$sourceZipDir = "$versionDir/$pluginAssemblyName"
$excludeDirs  = @('obj', 'bin', '.vs', '.git', 'PublishProfiles')
$excludeExts  = @('.user', '.pubxml')

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Fail       { param([string]$Message) throw $Message }

# Splits an absolute path into forward-slash segments relative to a root.
function Get-RelativeSegments {
    param([string]$Root, [string]$FullName)
    @(($FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/').Split('/') | Where-Object { $_ })
}

function New-Entry {
    param($Archive, [string]$EntryName, [string]$SourceFile)
    $entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($SourceFile)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    # counted here so the reported number is always what actually landed in the archive
    $script:entriesWritten++
    $script:fileCount++
}

function Test-ExcludedPath {
    # separator agnostic: works for both 'a\obj\b' and 'a/obj/b'
    param([string]$Root, [string]$FullName)
    foreach ($segment in @(Get-RelativeSegments -Root $Root -FullName $FullName)) {
        if ($excludeDirs -contains $segment) { return $true }
    }
    return ($excludeExts -contains [System.IO.Path]::GetExtension($FullName))
}

function Add-Tree {
    param($Archive, [string]$OnDiskRoot, [string]$ZipPrefix)

    # directory entries first, matching the layout of the official nopCommerce packages
    foreach ($dir in (Get-ChildItem -LiteralPath $OnDiskRoot -Recurse -Directory -Force | Sort-Object FullName)) {
        $segments = Get-RelativeSegments -Root $OnDiskRoot -FullName $dir.FullName
        if ($segments | Where-Object { $excludeDirs -contains $_ }) { continue }
        [void]$Archive.CreateEntry("$ZipPrefix/$($segments -join '/')/")
        $script:entriesWritten++
    }

    foreach ($file in (Get-ChildItem -LiteralPath $OnDiskRoot -Recurse -File -Force | Sort-Object FullName)) {
        if (Test-ExcludedPath -Root $OnDiskRoot -FullName $file.FullName) { continue }
        $segments = Get-RelativeSegments -Root $OnDiskRoot -FullName $file.FullName
        New-Entry -Archive $Archive -EntryName "$ZipPrefix/$($segments -join '/')" -SourceFile $file.FullName
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$entryCount = 0
$fileCount  = 0
$pluginJson = $null
$script:entriesWritten = 0
$script:fileCount = 0

if (-not $VerifyOnly) {
    # ------------------------------------------------------------ 1. build ----
    if (-not (Test-Path -LiteralPath $PluginProject)) { Fail "plugin project not found: $PluginProject" }
    if (-not (Test-Path -LiteralPath $nopWebProject))    { Fail "Nop.Web.csproj not found: $nopWebProject" }
    if (-not (Test-Path -LiteralPath $clearProj))        { Fail "ClearPluginAssemblies.proj not found: $clearProj" }

    if ($SkipBuild) {
        Write-Step "Skipping build (-SkipBuild), packaging $buildOutput"
    }
    else {
        Write-Step "Building $pluginAssemblyName ($Configuration) against $solutionDir"
        # NOTE: the plugin csproj references $(SolutionDir)\Presentation\Nop.Web\Nop.Web.csproj.
        # When the csproj is built outside the solution, $(SolutionDir) is empty and the build
        # fails with ~61 CS0246 errors, so it has to be passed explicitly.
        & dotnet build $PluginProject -c $Configuration -v minimal "-p:SolutionDir=$solutionDir\"
        if ($LASTEXITCODE -ne 0) { Fail "dotnet build failed (exit $LASTEXITCODE)" }
    }

    $builtAssembly = Join-Path $buildOutput "$pluginAssemblyName.dll"
    if (-not (Test-Path -LiteralPath $builtAssembly)) { Fail "build output not found: $builtAssembly" }

    # ------------------------------------- 2. guard against ref assembly ----
    # A .NET *reference assembly* has no method bodies: the plugin would upload fine and then
    # fail at load. It is easy to copy by mistake because it sits right next to the real
    # output under obj\<Config>\net9.0\ref\. Roslyn names it identically, so the only
    # reliable check is to compare it against the ref folder of whichever copy of the
    # project produced the build output (this repo, or the nopCommerce tree).
    $refSearchRoots = @(
        (Join-Path $projectRoot 'obj')
        (Join-Path $solutionDir "Plugins\$pluginAssemblyName\obj")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $refAssemblies = foreach ($root in $refSearchRoots) {
        Get-ChildItem -LiteralPath $root -Recurse -Filter "$pluginAssemblyName.dll" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -in @('ref', 'refint', 'bin') }
    }
    $assemblyHash = (Get-FileHash -LiteralPath $builtAssembly -Algorithm MD5).Hash
    foreach ($ref in $refAssemblies) {
        if ((Get-FileHash -LiteralPath $ref.FullName -Algorithm MD5).Hash -eq $assemblyHash) {
            Fail "build output is a reference assembly (identical to $($ref.FullName)); the plugin would fail to load"
        }
    }
    Write-Ok "assembly is a real build ($((Get-Item -LiteralPath $builtAssembly).Length) bytes, md5 $assemblyHash, checked $(@($refAssemblies).Count) reference assemblies)"

    # ---------------------------------------- 3. whitelist the build output ----
    # The build folder also receives the referenced Nop.Web project's output
    # (Nop.Web.staticwebassets.endpoints.json alone is ~4 MB) and the plugin's own
    # .deps.json. Only ship what nopCommerce actually needs.
    $wantedFiles = @("$pluginAssemblyName.dll", "$pluginAssemblyName.pdb", 'plugin.json', 'logo.png')
    $payload = foreach ($name in $wantedFiles) {
        $path = Join-Path $buildOutput $name
        if (-not (Test-Path -LiteralPath $path)) { Fail "expected build output missing: $name" }
        Get-Item -LiteralPath $path
    }
    $viewsDir = Join-Path $buildOutput 'Views'
    if (-not (Test-Path -LiteralPath $viewsDir)) { Fail "Views folder missing in build output" }
    $payload += Get-ChildItem -LiteralPath $viewsDir -Recurse -File
    Write-Ok "collected $($payload.Count) files from build output"

    # ------------------------------------------- 4. assert versions agree ----
    $pluginJson = Get-Content -LiteralPath (Join-Path $buildOutput 'plugin.json') -Raw | ConvertFrom-Json
    if ($pluginJson.SupportedVersions -notcontains $NopCommerceVersion) {
        Fail "plugin.json SupportedVersions ($($pluginJson.SupportedVersions -join ', ')) does not contain $NopCommerceVersion"
    }
    if ($pluginJson.SystemName -ne $pluginSystemName) { Fail "plugin.json SystemName '$($pluginJson.SystemName)' != '$pluginSystemName'" }
    if ($pluginJson.FileName -ne "$pluginAssemblyName.dll") { Fail "plugin.json FileName '$($pluginJson.FileName)' != '$pluginAssemblyName.dll'" }

    $uploadedItemsPath = Join-Path $repoRoot 'uploadedItems.json'
    if (-not (Test-Path -LiteralPath $uploadedItemsPath)) { Fail "uploadedItems.json not found: $uploadedItemsPath" }
    foreach ($item in (Get-Content -LiteralPath $uploadedItemsPath -Raw | ConvertFrom-Json)) {
        if ($item.DirectoryPath -ne "$versionDir/$pluginSystemName/") {
            Fail "uploadedItems.json DirectoryPath '$($item.DirectoryPath)' != '$versionDir/$pluginSystemName/'"
        }
        if ($item.SupportedVersion -ne $NopCommerceVersion) {
            Fail "uploadedItems.json SupportedVersion '$($item.SupportedVersion)' != '$NopCommerceVersion'"
        }
        if ($item.SystemName -ne $pluginSystemName) { Fail "uploadedItems.json SystemName '$($item.SystemName)' != '$pluginSystemName'" }
    }
    Write-Ok "plugin.json and uploadedItems.json agree on $versionDir / $pluginSystemName"

    # ---------------------------------------------------------- 5. zip it ----
    $zipDir = Split-Path -Parent $OutputZip
    if ($zipDir -and -not (Test-Path -LiteralPath $zipDir)) { New-Item -ItemType Directory -Path $zipDir -Force | Out-Null }
    if (Test-Path -LiteralPath $OutputZip) { Remove-Item -LiteralPath $OutputZip -Force }

    Write-Step "Writing $OutputZip"
    $script:entriesWritten = 0
    $script:fileCount = 0
    $archive = [System.IO.Compression.ZipFile]::Open($OutputZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        # binaries, staged from the whitelist so referenced-project output can never ship
        foreach ($file in $payload) {
            $segments = Get-RelativeSegments -Root $buildOutput -FullName $file.FullName
            New-Entry -Archive $archive -EntryName "$binaryZipDir/$($segments -join '/')" -SourceFile $file.FullName
        }
        Write-Ok "binaries: $script:fileCount files"

        # source, as shipped to the nopCommerce marketplace
        $beforeFiles = $script:fileCount
        Add-Tree -Archive $archive -OnDiskRoot $projectRoot -ZipPrefix $sourceZipDir
        Write-Ok "source: $($script:fileCount - $beforeFiles) files"

        # root files
        foreach ($name in @('Readme.txt', 'uploadedItems.json')) {
            $path = Join-Path $repoRoot $name
            if (-not (Test-Path -LiteralPath $path)) { Fail "missing $path" }
            New-Entry -Archive $archive -EntryName $name -SourceFile $path
        }
    }
    finally { $archive.Dispose() }
    $entryCount = $script:entriesWritten
    Write-Ok "$entryCount entries written ($fileCount files + $($entryCount - $fileCount) directories)"
}

# ---------------------------------------------------------- 6. verify it ----
# Replay the nopCommerce upload logic against the finished archive. Anything that would make
# the admin report "0 plugins and 0 themes have been uploaded" is caught here.
function Read-ZipEntryText {
    param($Entry)
    $stream = $Entry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    try { $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

$problems      = New-Object System.Collections.Generic.List[string]
$verifiedItems = New-Object System.Collections.Generic.List[string]

Write-Step "Verifying $OutputZip"
if (-not (Test-Path -LiteralPath $OutputZip)) { Fail "package not found: $OutputZip" }

$zip = [System.IO.Compression.ZipFile]::OpenRead($OutputZip)
try {
    $entries  = @($zip.Entries)
    $fullName = @($entries | ForEach-Object { $_.FullName })
    $entryCount = $entries.Count

    $backslash = @($fullName | Where-Object { $_ -like '*\*' })
    if ($backslash.Count) { $problems.Add("$($backslash.Count) backslash entry name(s), e.g. $($backslash[0])") }

    $residue = @($fullName | Where-Object { $_ -match '(^|/)(obj|bin)/' -or $_ -like '*.user' -or $_ -like '*.pubxml' })
    if ($residue.Count) { $problems.Add("$($residue.Count) build residue entry/entries") }

    $leak = @($fullName | Where-Object { $_ -match '/Nop\.Web\.' -or $_ -like '*deps.json' -or $_ -like '*staticwebassets*' })
    if ($leak.Count) { $problems.Add("$($leak.Count) unrelated referenced-project file(s) in the package") }

    # uploadedItems.json has to sit in the archive root (UploadService.GetUploadedItemsAsync)
    $itemsEntry = $entries | Where-Object { $_.Name -eq 'uploadedItems.json' -and $_.FullName -notmatch '/' }
    if (-not $itemsEntry) {
        $problems.Add('uploadedItems.json is not in the archive root')
    }
    else {
        foreach ($item in (Read-ZipEntryText $itemsEntry | ConvertFrom-Json)) {
            if (-not $item.Type) { $problems.Add('uploadedItems.json entry without Type'); continue }
            if ($item.SupportedVersion -and -not $item.SupportedVersion.Contains($NopCommerceVersion)) {
                $problems.Add("uploadedItems.json SupportedVersion '$($item.SupportedVersion)' excludes $NopCommerceVersion")
            }

            $itemPath  = "$($item.DirectoryPath.TrimEnd('/'))/"
            $descriptor = $entries | Where-Object { $_.FullName -eq "$itemPath" + 'plugin.json' }
            if (-not $descriptor) { $problems.Add("plugin.json is not resolvable at '$itemPath" + "plugin.json'"); continue }

            $descriptorJson = Read-ZipEntryText $descriptor | ConvertFrom-Json
            if (-not $descriptorJson.SupportedVersions.Contains($NopCommerceVersion)) {
                $problems.Add("plugin.json SupportedVersions '$($descriptorJson.SupportedVersions -join ',')' excludes $NopCommerceVersion")
            }

            $targetDir = ($itemPath.TrimEnd('/') -split '/')[-1]
            if ($targetDir -ne $descriptorJson.SystemName) {
                $problems.Add("deployed folder '$targetDir' != SystemName '$($descriptorJson.SystemName)'")
            }

            $extracted = @($entries | Where-Object { $_.FullName.StartsWith($itemPath, [System.StringComparison]::OrdinalIgnoreCase) })
            if (-not ($entries | Where-Object { $_.FullName -eq "$itemPath" + $descriptorJson.FileName })) {
                $problems.Add("main assembly '$($descriptorJson.FileName)' missing from the package")
            }
            $verifiedItems.Add("$(if($pluginJson){$pluginJson.FriendlyName}else{$descriptorJson.FriendlyName}) $(if($pluginJson){$pluginJson.Version}else{$descriptorJson.Version})")
            Write-Ok "would install to ~/Plugins/Uploaded/$targetDir ($($extracted.Count) entries, $($descriptorJson.FriendlyName) $($descriptorJson.Version))"
        }
    }
}
finally { $zip.Dispose() }

if ($problems.Count) {
    Write-Host ''
    Write-Host 'VERIFICATION FAILED' -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'VERIFICATION PASSED - package is uploadable' -ForegroundColor Green
Write-Host "  plugin  : $pluginSystemName ($($verifiedItems -join ', '))"
Write-Host "  target  : nopCommerce $NopCommerceVersion"
Write-Host "  entries : $entryCount"
Write-Host "  size    : $('{0:N0}' -f (Get-Item -LiteralPath $OutputZip).Length) bytes"
Write-Host "  zip     : $OutputZip"
exit 0
