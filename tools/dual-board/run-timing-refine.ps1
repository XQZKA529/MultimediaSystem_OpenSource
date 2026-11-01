param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][string]$BaseRun,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$boardRoot=Join-Path $workspace $Board
$base=(Resolve-Path -LiteralPath $BaseRun).Path
$project="MultimediaSystem_$Board"
$db=Join-Path $base ($project+'_pr.db')
if(-not(Test-Path -LiteralPath $db)){throw 'A completed routed database is required.'}
$expected=Get-Content -LiteralPath (Join-Path $base 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $boardRoot 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($expected.Count -ne $current.Count){throw 'Input set changed since the base route.'}
foreach($name in $expected.Keys){if($expected[$name] -ne $current[$name]){throw "Input changed: $name"}}
$run=Join-Path $boardRoot ('Runs/phy_'+$RunTag)
if(Test-Path -LiteralPath $run){throw 'Run exists; choose a new tag.'}
New-Item -ItemType Directory -Path $run | Out-Null
Copy-Item -LiteralPath (Join-Path $base 'inputs.json') -Destination (Join-Path $run 'inputs.json')
Copy-Item -LiteralPath (Join-Path $base 'settings.cfg') -Destination (Join-Path $run 'base-settings.cfg')
$sourcePath=$boardRoot.Replace('\','/')
$dbPath=$db.Replace('\','/')
$runPath=$run.Replace('\','/')
# TimingUltra's documented extra post-route rounds, applied to the same routed
# placement. Keep both corners, original constraints and native hold repair.
$entry=@"
import_device eagle_s20.db -package EG4S20BG256
open_project {$sourcePath/$project.al} -noanalyze
cd {$runPath}
source ./base-settings.cfg
import_db {$dbPath}
foreach {step parameter value} `$synWildParams {set_param `$step `$parameter `$value}
read_adc {$sourcePath/constr/$Board.adc}
clear_sdc -user
read_sdc {$sourcePath/constr/$Board.sdc}
set_param route fix_hold on
set_param route post_route_opt high
set_param route postrt_opt_extra_round 4
route -incremental
fix_hold
update_timing -mode final
report_timing_status -file ${project}_phy.ts
report_timing_summary -file ${project}_pr.timing
report_timing_summary -ep_num 200 -path_num 1 -viol_only -file critical-paths.timing
report_area -io_info -file ${project}_phy.area
report_qor -step route -file final.qor
export_db ${project}_pr.db
exit
"@
[IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') entry.tcl *> console.txt
    $output=Get-Content -LiteralPath console.txt -Raw
    if($LASTEXITCODE -ne 0 -or $output -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b'){
        throw 'Incremental timing experiment failed; inspect console.txt.'
    }
    foreach($artifact in @("${project}_pr.db","${project}_pr.timing",'final.qor')){
        if(-not(Test-Path -LiteralPath $artifact)){throw "Missing $artifact"}
    }
    # This custom entry completes the same route/report/export boundary as
    # MyFlow. Record completion only after TD succeeds and artifacts exist.
    New-Item -ItemType File -Path (Join-Path $run '.opt_route.end.f') | Out-Null
    & python (Join-Path $PSScriptRoot 'resource_experiment.py') report --board $Board --run $run
    if($LASTEXITCODE -ne 0){throw 'Source/report validation failed.'}
}finally{Pop-Location}
