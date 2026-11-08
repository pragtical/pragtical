#Requires -Version 7.3
# Temporary UCRT64 PR checks; run the actual packages without MSYS2 on PATH.
param(
  [Parameter(Mandatory = $true)]
  [string]$Archive,
  [Parameter(Mandatory = $true)]
  [string]$Installer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$testsPath = Join-Path $PSScriptRoot 'lua/tests'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pragtical-ucrt-$([guid]::NewGuid())"

function Invoke-PackageProgram([string]$Executable, [string[]]$Arguments,
                               [int]$Timeout = 120) {
  $start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
  $start.UseShellExecute = $false
  $start.WorkingDirectory = $testRoot
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  # Missing bundled DLLs must not be supplied by the CI build environment.
  $start.Environment['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
  $start.Environment['SDL_VIDEO_DRIVER'] = 'dummy'
  $start.Environment['SDL_AUDIO_DRIVER'] = 'dummy'
  $start.Environment['PRAGTICAL_RENDERER'] = 'surface'
  $start.Environment['PRAGTICAL_USERDIR'] = Join-Path $testRoot 'user'
  $start.Environment.Remove('PRAGTICAL_PREFIX') | Out-Null
  $process = [System.Diagnostics.Process]::Start($start)
  try {
    if (-not $process.WaitForExit($Timeout * 1000)) {
      $process.Kill($true)
      throw "Program timed out: $Executable $Arguments"
    }
    if ($process.ExitCode -ne 0) {
      throw "Program exited with code $($process.ExitCode): $Executable $Arguments"
    }
  } finally {
    $process.Dispose()
  }
}

function Test-Package([string]$Directory) {
  foreach ($name in @('pragtical.exe', 'pragtical.com', 'data/core/start.lua')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory $name))) {
      throw "Package is missing $name in $Directory"
    }
  }
  foreach ($name in @('pragtical.exe', 'pragtical.com')) {
    Invoke-PackageProgram (Join-Path $Directory $name) @('run', $smokeScript)
  }
  $ppm = Join-Path $Directory 'data/plugins/plugin_manager/ppm.x86_64-windows.exe'
  Invoke-PackageProgram $ppm @('--version')
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $smokeScript = Join-Path $testRoot 'smoke.lua'
  @'
assert(jit, "LuaJIT is missing")
local ffi = require "ffi"
ffi.cdef "void *ren_get_target_window_ffi(void);"
assert(ffi.C.ren_get_target_window_ffi, "FFI exports are missing")
local converted, err = encoding.convert(
  "UTF-8", "GB18030", string.char(178, 226, 202, 212), { strict = true }
)
assert(converted == "测试", err or "GB18030 conversion failed")
assert(encoding.convert("ASCII", "UTF-8", "€", { strict = true }) == nil,
  "Strict conversion replaced an unrepresentable character")
print("Packaged editor smoke test passed")
'@ | Set-Content -LiteralPath $smokeScript

  $portablePath = Join-Path $testRoot 'portable'
  Expand-Archive -LiteralPath $archivePath -DestinationPath $portablePath
  $packagePath = Join-Path $portablePath 'pragtical'
  Write-Host 'Testing the extracted portable ZIP without MSYS2 on PATH'
  Test-Package $packagePath
  Invoke-PackageProgram (Join-Path $packagePath 'pragtical.com') @('test', $testsPath) 600

  $installPath = Join-Path $testRoot 'installed'
  Invoke-PackageProgram $installerPath @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
    '/TASKS=', "/DIR=$installPath")
  try {
    if (Test-Path -LiteralPath (Join-Path $installPath 'user')) {
      throw 'The normal installer unexpectedly enabled portable mode.'
    }
    Write-Host 'Testing the installed editor without MSYS2 on PATH'
    Test-Package $installPath
  } finally {
    Invoke-PackageProgram (Join-Path $installPath 'unins000.exe') @(
      '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
  }
  Write-Host 'Verified the portable ZIP and installer'
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
