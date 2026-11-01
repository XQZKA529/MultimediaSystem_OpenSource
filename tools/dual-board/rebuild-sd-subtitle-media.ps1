param(
    [ValidatePattern('^[a-z0-9_]+$')][string]$RunTag='sd_subtitle_release',
    [string]$TdRoot='D:/AnLu_FPGA_environment',
    [switch]$ReuseSynthesis,
    [ValidatePattern('^[a-z0-9_]+$')][string]$SynthesisRunTag='',
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$board=Join-Path $root 'media'
if(-not $SynthesisRunTag){$SynthesisRunTag=$RunTag}
$syn=Join-Path $board ('Runs/syn_'+$SynthesisRunTag)
$run=Join-Path $board ('Runs/phy_'+$RunTag)
if(Test-Path -LiteralPath $run){throw 'Physical run already exists; select a fresh RunTag.'}
$td=Join-Path $TdRoot 'bin/td_commands_prompt.exe'
if(-not(Test-Path -LiteralPath $td)){throw 'TD executable not found; pass TdRoot.'}
if(-not $ReuseSynthesis){
    & (Join-Path $board 'build/run.ps1') -Stage syn -RunTag $SynthesisRunTag -TdRoot $TdRoot -MapMode area_prior -InferFsm off -AreaEffort high
}
foreach($name in @('inputs.json','MultimediaSystem_media_gate.db','.opt_gate.end.f')){
    if(-not(Test-Path -LiteralPath (Join-Path $syn $name))){throw "Missing complete synthesis artifact: $name"}
}
$currentInputs=(& (Join-Path $board 'build/input-fingerprint.ps1')) -join "`n"
if($currentInputs -ne (Get-Content -LiteralPath (Join-Path $syn 'inputs.json') -Raw)){throw 'Synthesis inputs differ from current workspace; rebuild synthesis.'}
New-Item -ItemType Directory -Path $run | Out-Null
Copy-Item -LiteralPath (Join-Path $syn 'inputs.json') -Destination (Join-Path $run 'inputs.json')
$config=@(
 'set ADCList [list {../../constr/media.adc}]',
 'set SDCList [list {../../constr/media.sdc}]',
 'set area_option -packarea','set device_name eagle_s20.db','set package_name EG4S20BG256',
 'set prj_name {MultimediaSystem_media}','set top_model_name {top_media}','set run_type phy',
 'set synWildParams {gate map_mode area_prior rtl infer_fsm off gate add_map_lut_struct high gate multi_thread_mapping partition route effort routability route fix_hold on place seed 5 place relaxation 0.85}',
 'set start_step opt_place','set end_step bitgen',
 ('set parent ../syn_'+$SynthesisRunTag),'set arr_filter false','set drHoldFix on'
)
[IO.File]::WriteAllText((Join-Path $run 'settings.cfg'),($config -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
$boardPath=$board.Replace('\','/');$runPath=$run.Replace('\','/')
$entry="source ./settings.cfg`ncd {$boardPath}`nopen_project MultimediaSystem_media.al -noanalyze`ncd {$runPath}`nset singleRun 1`nsource {$boardPath/build/MyFlow.tcl}`n"
[IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
if($PrepareOnly){Write-Host "Prepared signed release parameters: $run";exit 0}
Push-Location $run
try{
    $started=[DateTime]::UtcNow
    & $td 'entry.tcl' *> (Join-Path $run 'console.txt')
    $bit=Join-Path $run 'MultimediaSystem_media.bit'
    if(-not(Test-Path -LiteralPath $bit)){throw "TD did not produce bitstream; inspect $run/console.txt"}
    if((Get-Item -LiteralPath $bit).LastWriteTimeUtc -lt $started){throw 'Stale bitstream'}
    & (Join-Path $board 'build/check-reports.ps1') -RunDir $run
}finally{Pop-Location}
