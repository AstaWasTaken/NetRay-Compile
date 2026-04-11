param(
    [string]$OutputDir = "dist",
    [string]$LauncherName = "NetRay-Compile.exe",
    [string]$AssetName = "NetRay-Compile-windows-x86_64.zip"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutputDir = Join-Path $repoRoot $OutputDir
$payloadDir = Join-Path $resolvedOutputDir "windows-payload"
$payloadZip = Join-Path $resolvedOutputDir "windows-payload.zip"
$stubPath = Join-Path $resolvedOutputDir $LauncherName
$assetPath = Join-Path $resolvedOutputDir $AssetName
$launcherSource = Join-Path $repoRoot "tools\\launcher\\WindowsLauncher.cs"
$markerBytes = [System.Text.Encoding]::ASCII.GetBytes("NETRAY_PAYLOAD_V1`0")
$luneBinary = Get-ChildItem "$env:USERPROFILE\\.rokit\\tool-storage\\lune-org\\lune\\*\\lune.exe" -ErrorAction Stop |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName

New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null
if (Test-Path $payloadDir) {
    Remove-Item -Recurse -Force $payloadDir
}
New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $payloadDir "cli") | Out-Null

Copy-Item $luneBinary (Join-Path $payloadDir "lune.exe") -Force
Copy-Item (Join-Path $repoRoot "cli\\netray.luau") (Join-Path $payloadDir "cli\\netray.luau") -Force
Copy-Item (Join-Path $repoRoot "src") (Join-Path $payloadDir "src") -Recurse -Force

if (Test-Path $payloadZip) {
    Remove-Item -Force $payloadZip
}
Compress-Archive -Path (Join-Path $payloadDir "*") -DestinationPath $payloadZip -Force

if (Test-Path $stubPath) {
    Remove-Item -Force $stubPath
}
Add-Type -Path $launcherSource -OutputAssembly $stubPath -OutputType ConsoleApplication -ReferencedAssemblies "System.IO.Compression.FileSystem.dll"

$stubStream = [System.IO.File]::Open($stubPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
    $payloadBytes = [System.IO.File]::ReadAllBytes($payloadZip)
    $stubStream.Write($markerBytes, 0, $markerBytes.Length)
    $stubStream.Write($payloadBytes, 0, $payloadBytes.Length)
}
finally {
    $stubStream.Dispose()
}

if (Test-Path $assetPath) {
    Remove-Item -Force $assetPath
}
Compress-Archive -Path $stubPath -DestinationPath $assetPath -Force

Write-Host "Packaged Windows CLI asset at $assetPath"
