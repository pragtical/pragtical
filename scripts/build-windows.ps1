#Requires -Version 7.3
<#
.SYNOPSIS
Build, test, and package the x64 editor from an MSVC developer shell.
.DESCRIPTION
Requires Meson 1.12 or later, Ninja, CMake, Git, and Inno Setup 6.
Rolling and release builds use LTO and profile-guided optimization.
PPM is bundled from the release pinned by subprojects/ppm.wrap.
#>
param(
  [ValidateSet('pr', 'rolling', 'release')]
  [string]$Configuration = 'pr',
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
  [string]$Version = 'dev',
  [string]$BuildDir = 'build-windows-msvc',
  [string]$OutputDir = 'artifacts/windows',
  [switch]$TestInstaller
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

# Wait for GUI executables too, and keep tests away from the real user profile.
function Invoke-Editor([string]$Executable, [string[]]$Arguments,
                       [string]$UserDir, [int]$Timeout = 600) {
  $start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
  $start.UseShellExecute = $false
  $start.WorkingDirectory = $sourceDir
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $start.Environment['SDL_VIDEO_DRIVER'] = 'dummy'
  $start.Environment['SDL_AUDIO_DRIVER'] = 'dummy'
  $start.Environment['PRAGTICAL_RENDERER'] = 'surface'
  $start.Environment['PRAGTICAL_USERDIR'] = $UserDir
  $process = [System.Diagnostics.Process]::Start($start)
  try {
    if (-not $process.WaitForExit($Timeout * 1000)) {
      $process.Kill($true)
      throw "Editor timed out: $Executable $Arguments"
    }
    if ($process.ExitCode -ne 0) {
      throw "Editor exited with code $($process.ExitCode): $Arguments"
    }
  } finally {
    $process.Dispose()
  }
}

$sourceDir = Split-Path $PSScriptRoot -Parent
Push-Location $sourceDir
try {
  if (-not $IsWindows -or $env:VSCMD_ARG_TGT_ARCH -ne 'x64') {
    throw 'Run this script in an x64 MSVC developer PowerShell.'
  }
  $buildPath = [System.IO.Path]::GetFullPath($BuildDir)
  $outputPath = [System.IO.Path]::GetFullPath($OutputDir)
  $packagePath = Join-Path $outputPath 'pragtical'
  $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
  if (-not (Test-Path -LiteralPath $iscc)) {
    throw 'Install Inno Setup 6 before building Windows packages.'
  }

  $env:CC = 'cl'
  $env:CXX = 'cl'

  $buildType = if ($Configuration -eq 'release') { 'release' } else { 'debugoptimized' }
  $pgo = if ($Configuration -eq 'pr') { 'off' } else { 'generate' }
  $lto = if ($Configuration -eq 'pr') { 'false' } else { 'true' }
  $setup = @('setup', $buildPath, '--wrap-mode=forcefallback',
    "--buildtype=$buildType", '-Dppm=false', '-Djit=true',
    '-Ddefault_library=static', '-Db_vscrt=mt', '-Db_pgo=off',
    "-Db_lto=$lto", "-Dmsvc_pgo=$pgo")
  if (Test-Path -LiteralPath (Join-Path $buildPath 'meson-private/coredata.dat')) {
    $setup += '--wipe'
  }
  & meson @setup
  $sdlCache = Join-Path $buildPath 'subprojects/sdl3/__CMake_build/CMakeCache.txt'
  foreach ($probe in @('ICONV_IN_LIBICONV', 'LIBC_HAS_ICONV_H',
                       'LIBC_HAS_MALLOC', 'LIBC_HAS_MEMCPY', 'LIBC_HAS_STRLEN')) {
    if (-not (Select-String -LiteralPath $sdlCache -Pattern "^${probe}:INTERNAL=1$" -Quiet)) {
      throw "SDL's dependency check failed: $probe. Check its CMake configuration log."
    }
  }
  & meson compile -C $buildPath

  if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Recurse -Force
  }
  & meson install -C $buildPath --no-rebuild --destdir $packagePath

  # Run the build executables against the installed data. A portable user/
  # beside the staged executables would override PRAGTICAL_USERDIR.
  $runtimeData = Join-Path $buildPath 'src/data'
  if (Test-Path -LiteralPath $runtimeData) {
    Remove-Item -LiteralPath $runtimeData -Force
  }
  New-Item -ItemType Junction -Path $runtimeData -Target (Join-Path $packagePath 'data') | Out-Null
  $console = Join-Path $buildPath 'src/pragtical.com'
  $gui = Join-Path $buildPath 'src/pragtical.exe'

  if ($Configuration -ne 'pr') {
    # The GUI and console targets have separate profile databases. Train both
    # before asking MSVC to use their profiles, including exit-time flushing.
    foreach ($target in @('pragtical', 'pragtical_com')) {
      $executable = if ($target -eq 'pragtical') { $gui } else { $console }
      Invoke-Editor $executable @('run', '-n', 'scripts/lua/pgo.lua') `
        (Join-Path $buildPath "user-pgo-$target") 330
      $profiles = @(Get-ChildItem -LiteralPath (Join-Path $buildPath 'src') `
        -Filter "$target!*.pgc" | Where-Object Length -gt 0)
      if ($profiles.Count -eq 0) {
        throw "PGO training did not produce profiles for $target."
      }
    }
    & meson configure -Dmsvc_pgo=use $buildPath
    & meson compile -C $buildPath
    & meson install -C $buildPath --no-rebuild --destdir $packagePath
  }

  & "$PSScriptRoot/check-windows-version-info.ps1" -BuildDir $buildPath

  # Use the pinned plugin sources and corresponding standalone PPM release.
  # PPM itself still needs POSIX headers and is not built by MSVC.
  & meson subprojects download ppm
  $wrap = Get-Content -LiteralPath 'subprojects/ppm.wrap' -Raw
  if ($wrap -notmatch '(?m)^revision\s*=\s*(v[0-9][^\s]*)\s*$') {
    throw 'ppm.wrap must name a published PPM release.'
  }
  $ppmVersion = $Matches[1]
  $pluginPath = Join-Path $packagePath 'data/plugins/plugin_manager'
  Copy-Item -LiteralPath 'subprojects/ppm/plugins/plugin_manager' `
    -Destination (Join-Path $packagePath 'data/plugins') -Recurse -Force
  $ppm = Join-Path $pluginPath 'ppm.x86_64-windows.exe'
  Invoke-WebRequest -Uri "https://github.com/pragtical/plugin-manager/releases/download/$ppmVersion/ppm.x86_64-windows.exe" `
    -OutFile $ppm
  & $ppm --version

  Invoke-Editor $console @('test', 'scripts/lua/tests') (Join-Path $buildPath 'user-tests')

  # Exercise the native plugin ABI without linking a second Lua runtime.
  $smokeDir = Join-Path $buildPath 'native-smoke'
  New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
  $smokeSource = Join-Path $smokeDir 'msvc_smoke.c'
  @'
typedef struct lua_State lua_State;
__declspec(dllexport) int luaopen_pragtical_msvc_smoke(
    lua_State *L, void *(*api_require)(const char *)) {
  void (*pushboolean)(lua_State *, int) =
      (void (*)(lua_State *, int)) api_require("lua_pushboolean");
  if (!pushboolean) return 0;
  pushboolean(L, 1);
  return 1;
}
'@ | Set-Content -LiteralPath $smokeSource
  $smokeDll = Join-Path $smokeDir 'msvc_smoke.dll'
  & cl /nologo /LD /MT $smokeSource "/Fe:$smokeDll" "/Fo:$smokeDir/msvc_smoke.obj"
  $smokeScript = Join-Path $smokeDir 'smoke.lua'
  @"
assert(jit, 'LuaJIT is missing')
local ffi = require 'ffi'
ffi.cdef 'void *ren_get_target_window_ffi(void);'
assert(ffi.C.ren_get_target_window_ffi, 'FFI exports are missing')
assert(system.load_native_plugin('msvc_smoke', $(ConvertTo-Json $smokeDll -Compress)))
"@ | Set-Content -LiteralPath $smokeScript
  Invoke-Editor $console @('run', $smokeScript) (Join-Path $buildPath 'user-native-smoke')

  # Static dependencies need no import libraries, headers, or PDBs at runtime.
  foreach ($directory in @('lib', 'lib64', 'include')) {
    $path = Join-Path $packagePath $directory
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  }
  Get-ChildItem -LiteralPath $packagePath -Recurse -File -Include *.pdb,*.lib,*.exp |
    Remove-Item -Force

  $installName = "pragtical-$Version-windows-x86_64"
  Compress-Archive -LiteralPath $packagePath -DestinationPath "$outputPath/$installName.zip" -Force
  & $iscc '/DArch=x64' "/DPackageDir=$packagePath" "/O$outputPath" `
    "/FPragtical-$Version-x86_64-setup" (Join-Path $buildPath 'scripts/innosetup.iss')

  if ($TestInstaller) {
    $installPath = Join-Path $buildPath 'installer-test'
    $installer = Join-Path $outputPath "Pragtical-$Version-x86_64-setup.exe"
    $process = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
      '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
      '/TASKS=', "/DIR=`"$installPath`"")
    if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
    try {
      if (Test-Path -LiteralPath (Join-Path $installPath 'user')) {
        throw 'The normal installer unexpectedly enabled portable mode.'
      }
      Invoke-Editor (Join-Path $installPath 'pragtical.com') @('run', $smokeScript) `
        (Join-Path $buildPath 'user-installed-smoke')
    } finally {
      $process = Start-Process -FilePath (Join-Path $installPath 'unins000.exe') `
        -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
      if ($process.ExitCode -ne 0) { throw "Uninstaller failed: $($process.ExitCode)" }
    }
  }

  Write-Host "Windows packages are in $outputPath"
} finally {
  Pop-Location
}
