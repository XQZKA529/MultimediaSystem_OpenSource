param(
    [ValidatePattern('^[a-z0-9_]+$')][string]$RunTag=('zero_'+(Get-Date -Format 'yyyyMMdd_HHmmss')),
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
# Reproduce the media screening recipe without changing board defaults or
# qualification gates: medium mapping/placement, then high post-route effort.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$board=Join-Path $root 'media'
$project='MultimediaSystem_media'
$syn=Join-Path $board ('Runs/syn_'+$RunTag)
$place=Join-Path $board ('Runs/place_'+$RunTag)
$route=Join-Path $board ('Runs/phy_'+$RunTag+'_route')
foreach($path in @($syn,$place,$route)){
    if(Test-Path -LiteralPath $path){throw "Run exists; choose a new tag: $path"}
}
& (Join-Path $board 'build/run.ps1') -Stage syn -RunTag $RunTag -TdRoot $TdRoot `
    -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -InferFsm off
if($LASTEXITCODE -ne 0){throw 'Media synthesis failed.'}
foreach($name in @('.opt_gate.end.f','inputs.json',"${project}_gate.db")){
    if(-not(Test-Path -LiteralPath (Join-Path $syn $name))){throw "Incomplete synthesis: $name"}
}
$expected=Get-Content -LiteralPath (Join-Path $syn 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $board 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($current.Count -ne $expected.Count){throw 'Source set changed after synthesis.'}
foreach($name in $expected.Keys){if($current[$name] -ne $expected[$name]){throw "Input changed: $name"}}
New-Item -ItemType Directory -Path $place | Out-Null
Copy-Item -LiteralPath (Join-Path $syn 'inputs.json') -Destination (Join-Path $place 'inputs.json')
$settings=Get-Content -LiteralPath (Join-Path $syn 'settings.cfg') -Raw
$settings=$settings -replace '(?m)^set run_type syn','set run_type phy'
$settings=$settings -replace '(?m)^set start_step read_design','set start_step opt_place'
$settings=$settings -replace '(?m)^set end_step opt_gate','set end_step opt_place'
$settings=$settings -replace '(?m)^(set synWildParams \{[^\r\n]*)\}',
    '$1 route effort routability route fix_hold on place seed 3}'
$settings+="`nset parent ../syn_$RunTag`nset arr_filter false`nset drHoldFix on`n"
[IO.File]::WriteAllText((Join-Path $place 'settings.cfg'),$settings,[Text.UTF8Encoding]::new($false))
$boardPath=$board.Replace('\','/');$placePath=$place.Replace('\','/')
$entry=@"
source ./settings.cfg
cd {$boardPath}
open_project $project.al -noanalyze
cd {$placePath}
set singleRun 1
source {$boardPath/build/MyFlow.tcl}
exit
"@
[IO.File]::WriteAllText((Join-Path $place 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $place
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') entry.tcl *> console.txt
    if($LASTEXITCODE -ne 0 -or (Get-ChildItem -LiteralPath $place -Filter '*.error.f' -Force) -or
       -not(Test-Path -LiteralPath (Join-Path $place '.opt_place.end.f'))){
        throw "Media placement failed: $place/console.txt"
    }
}finally{Pop-Location}
& (Join-Path $PSScriptRoot 'run-route-from-place.ps1') -Board media -BoardRoot $board `
    -BaseRun $place -RunTag ($RunTag+'_route') -TdRoot $TdRoot -PostRouteEffort high -GenerateBit
if($LASTEXITCODE -ne 0){throw 'Media routing or qualification failed.'}
