param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$SynthesisRunTag,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [Parameter(Mandatory)][ValidateRange(0,2147483647)][int]$PlaceSeed,
    [ValidateSet('medium','high')][string]$PhysicalEffort='medium',
    [ValidateRange(0.5,1.0)][double]$PlaceRelaxation=0.85,
    [switch]$NativeRelaxation,
    [string]$BoardRoot='',
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
# Reuse only a complete, byte-identical synthesis. Area experiments keep the
# source fingerprint, native hold repair and constraints.
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $BoardRoot){$BoardRoot=Join-Path $workspace $Board}
$BoardRoot=(Resolve-Path -LiteralPath $BoardRoot).Path
$syn=Join-Path $BoardRoot ('Runs/syn_'+$SynthesisRunTag)
$run=Join-Path $BoardRoot ('Runs/phy_'+$RunTag)
if(Test-Path -LiteralPath $run){throw 'Physical run already exists; choose a fresh RunTag.'}
foreach($name in @('inputs.json','settings.cfg',"MultimediaSystem_${Board}_gate.db",'.opt_gate.end.f')){
    if(-not(Test-Path -LiteralPath (Join-Path $syn $name))){throw "Incomplete synthesis: $name"}
}
$expected=Get-Content -LiteralPath (Join-Path $syn 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $BoardRoot 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($expected.Count -ne $current.Count){throw 'Synthesis source set differs from current inputs.'}
foreach($name in $expected.Keys){if($expected[$name] -ne $current[$name]){throw "Synthesis input changed: $name"}}
$synSettings=Get-Content -LiteralPath (Join-Path $syn 'settings.cfg') -Raw
$parameters=[regex]::Match($synSettings,'(?m)^set synWildParams \{([^\r\n}]*)\}').Groups[1].Value
if(-not $parameters -or $parameters -match '\b(place|route)\b'){throw 'Expected synthesis-only parameters.'}
$parameters+=" route effort routability route fix_hold on place seed $PlaceSeed"
if($PhysicalEffort -eq 'high'){
    $parameters+=' place effort high place opt_timing high place logic_level_opt on place aggressive_opt 20 place aggr_neighbor_dist 5 place enhanced_beeline_opt 3 place timing_driven_mode on place shifter_opt on place crit_path_opt on place post_place_opt high route post_route_opt high'
}
if($Board -eq 'media' -and -not $NativeRelaxation){$parameters+=' place relaxation '+$PlaceRelaxation.ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)}
New-Item -ItemType Directory -Path $run | Out-Null
Copy-Item -LiteralPath (Join-Path $syn 'inputs.json') -Destination (Join-Path $run 'inputs.json')
$config=@(
 "set ADCList [list {../../constr/$Board.adc}]",
 "set SDCList [list {../../constr/$Board.sdc}]",
 'set area_option -packarea','set device_name eagle_s20.db','set package_name EG4S20BG256',
 "set prj_name {MultimediaSystem_$Board}","set top_model_name {top_$Board}",'set run_type phy',
 "set synWildParams {$parameters}",'set start_step opt_place','set end_step bitgen',
 "set parent ../syn_$SynthesisRunTag",'set arr_filter false','set drHoldFix on'
)
[IO.File]::WriteAllText((Join-Path $run 'settings.cfg'),($config -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
$boardPath=$BoardRoot.Replace('\','/');$runPath=$run.Replace('\','/')
$entry="source ./settings.cfg`ncd {$boardPath}`nopen_project MultimediaSystem_$Board.al -noanalyze`ncd {$runPath}`nset singleRun 1`nsource {$boardPath/build/MyFlow.tcl}`n"
[IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') 'entry.tcl' *> 'console.txt'
    $output=Get-Content -LiteralPath 'console.txt' -Raw
    if($LASTEXITCODE -ne 0 -or $output -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b' -or
       (Get-ChildItem -LiteralPath $run -Filter '*.error.f' -Force)){
        throw 'TD physical implementation failed; inspect console.txt.'
    }
    foreach($name in @("MultimediaSystem_${Board}.bit",'final.qor',"MultimediaSystem_${Board}_phy.ts")){
        if(-not(Test-Path -LiteralPath (Join-Path $run $name))){throw "Missing final artifact: $name"}
    }
    & (Join-Path $BoardRoot 'build/check-reports.ps1') -RunDir $run
}finally{Pop-Location}
