param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
# Explicit hardware-trial entry point. Formal flow and qualification are untouched.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$run=Join-Path $root "$Board/Runs/phy_$RunTag"
$project="MultimediaSystem_$Board"
$expected=Get-Content -LiteralPath (Join-Path $run 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $root "$Board/build/input-fingerprint.ps1")) | ConvertFrom-Json -AsHashtable
if($current.Count -ne $expected.Count){throw 'Build source set changed'}
foreach($name in $expected.Keys){if($current[$name] -ne $expected[$name]){throw "Input changed: $name"}}
$timing=Get-Content -LiteralPath (Join-Path $run ($project+'_phy.ts')) -Raw
$area=Get-Content -LiteralPath (Join-Path $run ($project+'_phy.area')) -Raw
$qor=Get-Content -LiteralPath (Join-Path $run 'final.qor') -Raw
$hold=[double]([regex]::Match($timing,'HWNS:\s*([-0-9.]+)ns').Groups[1].Value)
$holdTns=[double]([regex]::Match($timing,'HTNS:\s*([-0-9.]+)ns').Groups[1].Value)
$holdCount=[int]([regex]::Match($qor,'Num of violated H-EP\s*\|\s*(\d+)').Groups[1].Value)
if($timing -notmatch 'HWNS:' -or $timing -notmatch 'HTNS:' -or $qor -notmatch 'Num of violated H-EP' -or $hold -lt 0 -or $holdTns -ne 0 -or $holdCount -ne 0){throw 'A hardware trial still requires zero hold violations'}
foreach($item in @(@('lut',19600),@('reg',19600),@('bram9k',64),@('bram32k',16),@('dsp',29),@('pll',4))){
    $match=[regex]::Match($area,'(?m)^\s*#'+$item[0]+'\s+(\d+)')
    if(-not $match.Success -or [int]$match.Groups[1].Value -gt $item[1]){throw "Illegal physical resource: $($item[0])"}
}
$slice=[regex]::Match($qor,'#slices\s*\|\s*(\d+)')
if(-not $slice.Success -or [int]$slice.Groups[1].Value -gt 9800){throw 'Slice capacity exceeded'}
$db=Join-Path $run ($project+'_pr.db')
if(-not(Test-Path -LiteralPath $db)){throw 'Missing completed routed database'}
$bit=Join-Path $run ($project+'_EMERGENCY_TIME_TRIAL.bit')
if(Test-Path -LiteralPath $bit){throw 'Trial bit already exists'}
$entry=@"
# Authorized emergency timestamp hardware trial. Setup is NOT certified by this entry point.
import_device eagle_s20.db -package EG4S20BG256
import_db {$($db.Replace('\','/'))}
bitgen -bit ${project}_EMERGENCY_TIME_TRIAL.bit
export_bitgen_param -file emergency_time_trial_bitgen_param.txt
exit
"@
[IO.File]::WriteAllText((Join-Path $run 'generate-emergency-time-trial.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') 'generate-emergency-time-trial.tcl' *> 'emergency-time-trial-bitgen.txt'
    if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $bit)){throw 'Trial bit generation failed'}
}finally{Pop-Location}
Write-Host "GENERATED HARDWARE TRIAL: $bit; formal qualification is separate"
