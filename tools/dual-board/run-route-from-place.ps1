param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][string]$BaseRun,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [string]$BoardRoot='',
    [string]$TdRoot='D:/AnLu_FPGA_environment',
    [ValidateSet('inherit','medium','high')][string]$PostRouteEffort='inherit',
    [ValidateSet('inherit','normal','routability')][string]$RouteEffort='inherit',
    [ValidateSet('inherit','timing')][string]$RoutePriority='inherit',
    [switch]$GenerateBit
)
# Resume interrupted routing from an immutable, completed placement. Write the
# resumed result to a new run, and keep the original reports and logs intact.
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $BoardRoot){$BoardRoot=Join-Path $workspace $Board}
$BoardRoot=(Resolve-Path -LiteralPath $BoardRoot).Path
$base=(Resolve-Path -LiteralPath $BaseRun).Path
$project="MultimediaSystem_$Board"
foreach($name in @('inputs.json','settings.cfg','.opt_place.end.f',"${project}_place.db")){
    if(-not(Test-Path -LiteralPath (Join-Path $base $name))){throw "Incomplete placement: $name"}
}
$expected=Get-Content -LiteralPath (Join-Path $base 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $BoardRoot 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($expected.Count -ne $current.Count){throw 'Placement source set differs from current inputs.'}
foreach($name in $expected.Keys){if($expected[$name] -ne $current[$name]){throw "Placement input changed: $name"}}
$run=Join-Path $BoardRoot ('Runs/phy_'+$RunTag)
if(Test-Path -LiteralPath $run){throw 'Run exists; choose a new tag.'}
New-Item -ItemType Directory -Path $run | Out-Null
Copy-Item -LiteralPath (Join-Path $base 'inputs.json') -Destination (Join-Path $run 'inputs.json')
Copy-Item -LiteralPath (Join-Path $base "${project}_place.db") -Destination (Join-Path $run "${project}_place.db")
$settings=Get-Content -LiteralPath (Join-Path $base 'settings.cfg') -Raw
$settings=$settings -replace '(?m)^set start_step \w+','set start_step opt_route'
$settings=$settings -replace '(?m)^set end_step \w+','set end_step opt_route'
if($PostRouteEffort -ne 'inherit'){
    if($settings -notmatch 'route post_route_opt \w+'){
        # A medium placement uses the native auto default. Record the parent
        # settings unchanged and set the requested effort only in this run.
        if($settings -notmatch '(?m)^set synWildParams \{[^\r\n]*\}'){
            throw 'Missing native parameter list; cannot set post-route effort.'
        }
        $settings=$settings -replace '(?m)^(set synWildParams \{[^\r\n]*)\}',"`$1 route post_route_opt $PostRouteEffort}"
    }else{
        $settings=$settings -replace 'route post_route_opt \w+',"route post_route_opt $PostRouteEffort"
    }
}
if($GenerateBit){$settings=$settings -replace '(?m)^set end_step \w+','set end_step bitgen'}
if($RouteEffort -ne 'inherit'){
    if($settings -notmatch 'route effort \w+'){
        throw 'Base run does not explicitly specify route effort.'
    }
    $settings=$settings -replace 'route effort \w+',"route effort $RouteEffort"
}
if($RoutePriority -ne 'inherit'){
    if($settings -match 'route priority \w+'){
        $settings=$settings -replace 'route priority \w+',"route priority $RoutePriority"
    }else{
        $settings=$settings -replace '(?m)^(set synWildParams \{[^\r\n]*)\}',"`$1 route priority $RoutePriority}"
    }
}
[IO.File]::WriteAllText((Join-Path $run 'settings.cfg'),$settings,[Text.UTF8Encoding]::new($false))
$parentInfo=@{
    base_run=$base
    placement_sha256=(Get-FileHash -LiteralPath (Join-Path $base "${project}_place.db") -Algorithm SHA256).Hash.ToLowerInvariant()
    original_settings_sha256=(Get-FileHash -LiteralPath (Join-Path $base 'settings.cfg') -Algorithm SHA256).Hash.ToLowerInvariant()
    post_route_effort=$PostRouteEffort
    route_effort=$RouteEffort
    route_priority=$RoutePriority
    generate_bit=$GenerateBit.IsPresent
}
$parentInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'route-parent.json') -Encoding utf8
$sourcePath=$BoardRoot.Replace('\','/')
$runPath=$run.Replace('\','/')
$entry=@"
source ./settings.cfg
cd {$sourcePath}
open_project $project.al -noanalyze
cd {$runPath}
set singleRun 1
set sp 1
source {$sourcePath/build/MyFlow.tcl}
exit
"@
[IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') entry.tcl *> console.txt
    $output=Get-Content -LiteralPath console.txt -Raw
    if($LASTEXITCODE -ne 0 -or $output -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b' -or
       (Get-ChildItem -LiteralPath $run -Filter '*.error.f' -Force)){
        throw 'Resumed routing failed; inspect console.txt.'
    }
    & python (Join-Path $PSScriptRoot 'resource_experiment.py') report --board $Board --run $run
    if($LASTEXITCODE -ne 0){throw 'Resumed route/report validation failed.'}
    if($GenerateBit){
        & (Join-Path $BoardRoot 'build/check-reports.ps1') -RunDir $run
        if($LASTEXITCODE -ne 0){throw 'Resumed build qualification failed.'}
    }
}finally{Pop-Location}
