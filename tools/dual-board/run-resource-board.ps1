param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][string]$BoardRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [int]$PlaceSeed=-1,
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
$ErrorActionPreference='Stop'
$BoardRoot=(Resolve-Path -LiteralPath $BoardRoot).Path
if($PlaceSeed -lt 0){$PlaceSeed=if($Board -eq 'media'){3}else{5}}
& (Join-Path $BoardRoot 'build/run.ps1') -Stage syn -RunTag $RunTag -TdRoot $TdRoot
if($LASTEXITCODE -ne 0){throw 'Synthesis failed.'}
$options=@{Board=$Board;BoardRoot=$BoardRoot;SynthesisRunTag=$RunTag;RunTag=$RunTag;PlaceSeed=$PlaceSeed;TdRoot=$TdRoot}
if($Board -eq 'render'){$options.PhysicalEffort='high';$options.SkipPostPlaceOpt=$true}
& (Join-Path $PSScriptRoot 'run-resource-physical.ps1') @options
if($LASTEXITCODE -ne 0){throw 'Physical implementation failed.'}
