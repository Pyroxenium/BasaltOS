# Builds the packed BasaltOS image into build\dist and, when a BasaltOSStore
# checkout is found, the packed store into build\dist-store.
#   -Store <dir>   store repository to pack (default: ..\BasaltOSStore next to this repository)
#   -Publish       also copy the image to dist\ in the repository, where the installer finds it:
#                  dist\install-manifest.txt and the image itself under dist\os\. Commit dist\
#                  together with the sources it was built from.
# The source tree and the store repository are only read; -Publish replaces dist\.
param(
    [string]$Store,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $env:LOCALAPPDATA 'CraftOS-PC\CraftOS-PC_console.exe'
$out = Join-Path $repo 'build'
if (-not $Store) { $Store = Join-Path (Split-Path $repo -Parent) 'BasaltOSStore' }

# A private CraftOS-PC data directory keeps the real computers untouched.
$data = Join-Path $out '.craftos'
New-Item -ItemType Directory -Force $data | Out-Null
$report = Join-Path $out 'build-report.txt'
if (Test-Path $report) { Remove-Item $report }

$arguments = @(
    '--headless', '--directory', $data,
    '--mount-ro', "src=$(Join-Path $repo 'os')",
    '--mount-ro', "pack=$(Join-Path $PSScriptRoot 'pack')",
    '--mount-rw', "out=$out"
)
if (Test-Path (Join-Path $Store 'catalog.json')) {
    $arguments += '--mount-ro', "store=$Store"
}
$arguments += '--script', (Join-Path $PSScriptRoot 'pack\build.lua')

& $exe @arguments | Out-Null
$code = $LASTEXITCODE

if (Test-Path $report) { Get-Content $report } else { Write-Output 'BUILD FAILED: no report was written.'; $code = 1 }

if ($code -eq 0 -and $Publish) {
    # dist\ is laid out like the repository root as the installer sees it.
    $published = Join-Path $repo 'dist'
    if (Test-Path $published) { Remove-Item $published -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $published 'os') | Out-Null
    Copy-Item (Join-Path $out 'dist\*') (Join-Path $published 'os') -Recurse
    Copy-Item (Join-Path $out 'install-manifest.txt') $published
    Write-Output ''
    Write-Output "Published the packed image to $published"
}
exit $code
