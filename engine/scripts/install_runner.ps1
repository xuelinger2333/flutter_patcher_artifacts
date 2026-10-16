# Provision a replaceable Windows x64 engine runner.
# Usage: Get-Content token.txt | .\install_runner.ps1 <owner/repository> <runner-name>
# The registration token is read from stdin. Prerequisites are checked, never
# installed: Visual Studio 2026/2022 with "Desktop development with C++" and a
# Windows 10/11 SDK, Git, Python 3 on PATH, and a short FLUTTER_PATCHER_ENGINE_HOME on a drive
# with at least 40 GB free (engine checkout ~20 GB, build ~2 GB, SDK ~1 GB).
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunnerName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error "ASSERTION_FAILED: $Message"
    exit 1
}

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail 'invalid repository' }
if ($RunnerName -notmatch '^[A-Za-z0-9_.-]+$') { Fail 'invalid runner name' }
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    Fail 'requires Windows x64'
}

$home_dir = if ($env:FLUTTER_PATCHER_ENGINE_HOME) { $env:FLUTTER_PATCHER_ENGINE_HOME } else { Fail 'set FLUTTER_PATCHER_ENGINE_HOME to a short absolute path, e.g. D:\fpe' }
if (-not [System.IO.Path]::IsPathRooted($home_dir) -or $home_dir.Length -gt 24) {
    Fail 'FLUTTER_PATCHER_ENGINE_HOME must be a short absolute path (MAX_PATH), e.g. D:\fpe'
}
New-Item -ItemType Directory -Force -Path $home_dir | Out-Null
$drive = (Get-Item $home_dir).PSDrive
if ($drive.Free -lt 40GB) { Fail "less than 40 GB free on $($drive.Name):" }

foreach ($tool in @('git', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "required command missing: $tool" }
}
$python_version = & python -c 'import sys; print(sys.version_info >= (3, 10))' 2>$null
if ($python_version -ne 'True') { Fail 'python on PATH must be CPython 3.10 or newer (not the Microsoft Store alias)' }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Fail 'Visual Studio Installer (vswhere.exe) not found' }
$studio = & $vswhere -latest -prerelease -products * -version '[17.0,19.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $studio) { Fail 'Visual Studio 2026/2022 with the C++ x64 toolset (VC.Tools.x86.x64) not found' }
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
if (-not (Get-ChildItem $kits -Directory -Filter '10.*' -ErrorAction SilentlyContinue)) {
    Fail 'Windows 10/11 SDK not found under Windows Kits'
}
Write-Host "Visual Studio: $studio"

$runner = Join-Path $home_dir 'actions-runner'
if (Test-Path $runner) { Fail 'runner directory already exists' }
New-Item -ItemType Directory -Path $runner | Out-Null
Set-Location $runner
$version = '2.337.0'
$archive = "actions-runner-win-x64-$version.zip"
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$version/$archive" -OutFile $archive
$expected = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'
$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
if ($actual -ne $expected) { Fail "runner archive SHA-256 mismatch: $actual" }
Expand-Archive -Path $archive -DestinationPath $runner
Remove-Item $archive

$token = [Console]::In.ReadLine()
if (-not $token) { Fail 'registration token missing on stdin' }
$token = $token.Trim()
& .\config.cmd --unattended --url "https://github.com/$Repository" --token $token `
    --name $RunnerName --labels engine-builder --work _work --disableupdate
if ($LASTEXITCODE -ne 0) { Fail 'runner configuration failed' }
Remove-Variable token
Write-Host "Runner configured in $runner. Start it with .\run.cmd, or re-run config.cmd with --runasservice from an elevated prompt; the job reads FLUTTER_PATCHER_ENGINE_HOME from the repository variable ENGINE_WORK_DIR (set it to $home_dir)."
