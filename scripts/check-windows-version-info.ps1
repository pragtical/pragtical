param(
  [Parameter(Mandatory = $true)]
  [string]$BuildDir
)

$ErrorActionPreference = 'Stop'

function Assert-Equal([string]$Name, $Actual, $Expected) {
  if ($Actual -cne $Expected) {
    throw ("{0}: expected '{1}', got '{2}'" -f $Name, $Expected, $Actual)
  }
}

$buildPath = (Resolve-Path -LiteralPath $BuildDir).Path
$projectInfoPath = Join-Path $buildPath 'meson-info/intro-projectinfo.json'
$exePath = Join-Path $buildPath 'src/pragtical.exe'
$projectVersion = (Get-Content -LiteralPath $projectInfoPath -Raw |
  ConvertFrom-Json).version
if ($projectVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw "Unexpected Meson project version: $projectVersion"
}

$expectedVersion = "${projectVersion}.0"
$versionInfo = (Get-Item -LiteralPath $exePath).VersionInfo
Assert-Equal 'CompanyName' $versionInfo.CompanyName 'Pragtical Team'
Assert-Equal 'FileDescription' $versionInfo.FileDescription 'Pragtical'
Assert-Equal 'ProductName' $versionInfo.ProductName 'Pragtical'
Assert-Equal 'InternalName' $versionInfo.InternalName 'pragtical'
Assert-Equal 'OriginalFilename' $versionInfo.OriginalFilename 'pragtical.exe'
Assert-Equal 'FileVersion' $versionInfo.FileVersion $expectedVersion
Assert-Equal 'ProductVersion' $versionInfo.ProductVersion $expectedVersion

$expectedParts = @($projectVersion.Split('.') | ForEach-Object { [int]$_ }) + @(0)
$fileParts = @($versionInfo.FileMajorPart, $versionInfo.FileMinorPart,
  $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart)
$productParts = @($versionInfo.ProductMajorPart, $versionInfo.ProductMinorPart,
  $versionInfo.ProductBuildPart, $versionInfo.ProductPrivatePart)
for ($i = 0; $i -lt 4; $i++) {
  Assert-Equal "FILEVERSION part $i" $fileParts[$i] $expectedParts[$i]
  Assert-Equal "PRODUCTVERSION part $i" $productParts[$i] $expectedParts[$i]
}

Write-Host "Verified Windows EXE version information: $expectedVersion"
