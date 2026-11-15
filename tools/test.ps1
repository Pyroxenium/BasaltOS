# Runs the package tests headless in CraftOS-PC. Build first: tools\build.ps1.
#   -Only <suite>,...   run only these suites (runtime, source, apps, game, store)
#   -Show               print the full report of every suite, not only of failed ones
#   -TimeoutSeconds     limit for one suite (default 120)
# Every suite gets a fresh throwaway computer under build\run. Exit code 1 if a suite fails.
param(
    [string[]]$Only,
    [switch]$Show,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $env:LOCALAPPDATA 'CraftOS-PC\CraftOS-PC_console.exe'
$tests = Join-Path $PSScriptRoot 'test'
$dist = Join-Path $repo 'build\dist'
$store = Join-Path $repo 'build\dist-store'
$runs = Join-Path $repo 'build\run'

if (-not (Test-Path (Join-Path $dist 'startup.lua'))) {
    Write-Output 'No packed image found. Run tools\build.ps1 first.'
    exit 1
}
if (Test-Path $runs) { Remove-Item $runs -Recurse -Force }

# Starts the emulator on a data directory and waits for it to shut itself down.
function Invoke-Emulator([string]$Data, [string]$Script) {
    $arguments = @('--headless', '--directory', "`"$Data`"")
    if ($Script) { $arguments += '--script', "`"$Script`"" }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $Data 'stdout.txt') `
        -RedirectStandardError (Join-Path $Data 'stderr.txt')
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        $process.WaitForExit()
        return $false
    }
    return $true
}

function New-Computer([string]$Suite) {
    $data = Join-Path $runs $Suite
    New-Item -ItemType Directory -Force (Join-Path $data 'computer\0') | Out-Null
    return $data
}

# What one emulator run left behind: the report and whether it passed.
function Read-Outcome([bool]$Finished, [string]$Result) {
    $lines = if (Test-Path $Result) { @(Get-Content $Result) } else { @() }
    if (-not $Finished) { $lines += "timed out after $TimeoutSeconds s" }
    if ($lines.Count -eq 0) { $lines += 'no test result was written' }
    return @{ Passed = $Finished -and $lines[-1] -eq 'RESULT: passed'; Lines = $lines }
}

# Boots an image with the test harness in front of its boot loader, once per
# phase. Phases are suites of test\steps.lua and share one computer, so a
# later phase sees what an earlier one installed.
function Invoke-BootSuite([string[]]$Phases, [string]$Image, [string[]]$Apps = @(), [switch]$WithStore) {
    $data = New-Computer $Phases[0]
    $computer = Join-Path $data 'computer\0'
    # Accounts and installed apps of a development computer stay where they are.
    Get-ChildItem $Image | Where-Object { $_.Name -notin 'users', 'apps' } |
        Copy-Item -Destination $computer -Recurse -Force
    foreach ($state in 'system\config.dat', 'system\logs') {
        $path = Join-Path $computer $state
        if (Test-Path $path) { Remove-Item $path -Recurse -Force }
    }
    foreach ($app in $Apps) {
        Copy-Item $app (Join-Path $computer 'system\apps') -Recurse -Force
    }
    if ($WithStore) {
        Copy-Item $store (Join-Path $computer 'teststore') -Recurse
        # A packed image keeps its services inside a package, so the folder is new.
        $services = Join-Path $computer 'system\services'
        New-Item -ItemType Directory -Force $services | Out-Null
        Copy-Item (Join-Path $tests 'storetest.lua') $services
    }

    Move-Item (Join-Path $computer 'startup.lua') (Join-Path $computer 'boot.lua')
    Copy-Item (Join-Path $tests 'boottest.lua') (Join-Path $computer 'startup.lua')
    Copy-Item (Join-Path $tests 'steps.lua') (Join-Path $computer 'teststeps.lua')

    $result = Join-Path $computer 'testresult.txt'
    $lines = @()
    foreach ($phase in $Phases) {
        Set-Content (Join-Path $computer 'testsuite.txt') $phase -NoNewline
        if (Test-Path $result) { Remove-Item $result }
        $outcome = Read-Outcome (Invoke-Emulator $data) $result
        $lines += $outcome.Lines
        if (-not $outcome.Passed) { return @{ Passed = $false; Lines = $lines } }
    }
    return @{ Passed = $true; Lines = $lines }
}

function Invoke-RuntimeSuite {
    $data = New-Computer 'runtime'
    $computer = Join-Path $data 'computer\0'
    New-Item -ItemType Directory -Force (Join-Path $computer 'system\boot') | Out-Null
    Copy-Item (Join-Path $dist 'system\boot\bpk.lua') (Join-Path $computer 'system\boot')
    Copy-Item (Join-Path $dist 'system\apps\calculator') (Join-Path $computer 'stage') -Recurse

    $finished = Invoke-Emulator $data (Join-Path $tests 'runtimetest.lua')
    return Read-Outcome $finished (Join-Path $computer 'testresult.txt')
}

$hasStore = Test-Path (Join-Path $store 'catalog.json')
$suites = [ordered]@{
    runtime = @{ Title = 'package runtime'; Run = { Invoke-RuntimeSuite } }
    source  = @{ Title = 'unpacked source tree boots'; Run = { Invoke-BootSuite 'source' (Join-Path $repo 'os') } }
    apps    = @{ Title = 'packed image boots and runs apps'; Run = { Invoke-BootSuite 'apps' $dist } }
    game    = @{ Title = 'packed Obsidian game runs'; NeedsStore = $true
                 Run = { Invoke-BootSuite 'game' $dist @(Join-Path $store 'apps\spaceinvaders') } }
    store   = @{ Title = 'store installs a packed app, which survives a reboot'; NeedsStore = $true
                 Run = { Invoke-BootSuite 'store', 'store_reboot' $dist -WithStore } }
}

$failed = 0
foreach ($name in $suites.Keys) {
    if ($Only -and $Only -notcontains $name) { continue }
    $suite = $suites[$name]
    if ($suite.NeedsStore -and -not $hasStore) {
        Write-Output ("SKIPPED  {0,-8} {1} (no packed store in build\dist-store)" -f $name, $suite.Title)
        continue
    }

    $outcome = & $suite.Run
    $passed = $outcome.Passed
    $lines = $outcome.Lines

    Write-Output ("{0}  {1,-8} {2}" -f $(if ($passed) { 'PASSED ' } else { 'FAILED ' }), $name, $suite.Title)
    if (-not $passed) { $failed++ }
    if ($Show -or -not $passed) { $lines | ForEach-Object { Write-Output "  $_" } }
}

if ($failed -gt 0) { Write-Output "$failed suite(s) failed."; exit 1 }
Write-Output 'All suites passed.'
exit 0
