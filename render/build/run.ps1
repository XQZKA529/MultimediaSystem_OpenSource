param([ValidateSet('project','syn','phy','all')][string]$Stage='all',[string]$TdRoot=$env:TD_ROOT,
    [ValidateSet('auto','area_prior')][string]$MapMode='area_prior',[ValidatePattern('^[a-z0-9_]*$')][string]$RunTag='',
    [ValidateSet('auto','off','one_hot')][string]$InferFsm='off',[ValidateSet('auto','high')][string]$AreaEffort='high',
    [ValidateSet('medium','high')][string]$PhysicalEffort='medium',
    [ValidateRange(0,2147483647)][int]$PlaceSeed=4)
$ErrorActionPreference='Stop'
$boardRoot=Split-Path -Parent $PSScriptRoot
$board='render'
$project='MultimediaSystem_'+$board
if(-not $TdRoot){
    $exe=Get-Command td_commands_prompt.exe -ErrorAction SilentlyContinue
    if($exe){$TdRoot=Split-Path -Parent (Split-Path -Parent $exe.Source)}
    else{$TdRoot='D:/AnLu_FPGA_environment'}
}
$td=Join-Path $TdRoot 'bin/td_commands_prompt.exe'
if(-not (Test-Path -LiteralPath $td)){throw 'Set TD_ROOT or pass -TdRoot pointing to the installed TD.'}
$runRoot=Join-Path $boardRoot 'Runs'
New-Item -ItemType Directory -Force $runRoot | Out-Null
$prjLog=Join-Path $runRoot 'project.txt'
if($Stage -in @('project','syn','all')){
    Push-Location $boardRoot
    try { & $td 'build/project.tcl' *> $prjLog } finally {Pop-Location}
    if(-not ((Get-Content -LiteralPath $prjLog -Raw) -match 'BOARD_PROJECT_CREATED')){Get-Content $prjLog;throw 'TD project generation failed'}
}
if($Stage -eq 'project'){Write-Host "Created $project.al";exit 0}
foreach($step in @('syn','phy')){
    if($Stage -ne 'all' -and $Stage -ne $step){continue}
    $suffix=if($RunTag){'_'+$RunTag}else{''}
    $run=Join-Path $runRoot ($step+$suffix)
    New-Item -ItemType Directory -Force $run | Out-Null
    & (Join-Path $PSScriptRoot 'input-fingerprint.ps1') -Output (Join-Path $run 'inputs.json')
    if($step -eq 'phy'){
        $dbSynInputs=Join-Path $runRoot ("syn$suffix/inputs.json")
        if(-not (Test-Path -LiteralPath $dbSynInputs)){throw 'Rebuild synthesis with the current input fingerprint flow.'}
        if((Get-Content -LiteralPath $dbSynInputs -Raw) -ne (Get-Content -LiteralPath (Join-Path $run 'inputs.json') -Raw)){throw 'Inputs changed since synthesis: run -Stage all.'}
    }
    $rootPath=$boardRoot.Replace('\','/')
    $toolPath=$TdRoot.Replace('\','/')
    $configuration=@(
        "set ADCList [list {../../constr/$board.adc}]",
        "set SDCList [list {../../constr/$board.sdc}]",
        'set area_option -packarea','set device_name eagle_s20.db','set package_name EG4S20BG256',
        "set prj_name {$project}","set top_model_name {top_$board}","set run_type $step"
    )
    $configuration+="set synWildParams {gate map_mode $MapMode rtl infer_fsm $InferFsm}"
    if($AreaEffort -eq 'high'){$configuration[-1]=$configuration[-1] -replace '}$',' gate add_map_lut_struct high gate multi_thread_mapping partition}'}
    if($step -eq 'syn'){
        $configuration+=@('set start_step read_design','set end_step opt_gate')
        $flow="$toolPath/doc/scripts/DefaultFlow.tcl"
    }else{
        $configuration+=@('set start_step opt_place','set end_step bitgen',"set parent ../syn$suffix",'set arr_filter false','set drHoldFix on')
        if($PhysicalEffort -eq 'high'){
            $configuration=$configuration | ForEach-Object {
                if($_ -like 'set synWildParams *'){$_ -replace '}$',' place effort high place opt_timing high place logic_level_opt on place aggressive_opt 20 place aggr_neighbor_dist 5 place enhanced_beeline_opt 3 place timing_driven_mode on place shifter_opt on place crit_path_opt on place post_place_opt high route post_route_opt high}'}else{$_}
            }
        }
        $configuration=$configuration | ForEach-Object {
            if($_ -like 'set synWildParams *'){$_ -replace '}$'," route effort routability route fix_hold on place seed $PlaceSeed}"}else{$_}
        }
        $flow="$rootPath/build/MyFlow.tcl"
    }
    # [list ...] is Tcl code and must remain literal; braces quote path spaces.
    $configuration=$configuration | ForEach-Object {$_ -replace '^set (ADCList|SDCList) \[list (.*)\]$','set $1 [list $2]'}
    [IO.File]::WriteAllText((Join-Path $run 'settings.cfg'),($configuration -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $analyzeOption=if($step -eq 'syn'){''}else{' -noanalyze'}
    $runPath=$run.Replace('\','/')
    $entry="source ./settings.cfg`ncd {$rootPath}`nopen_project $project.al$analyzeOption`ncd {$runPath}`nset singleRun 1`nsource {$flow}`n"
    [IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
    Get-ChildItem -LiteralPath $run -Filter '*.error.f' -Force | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    Push-Location $run
    try {
        $started=[DateTime]::UtcNow
        & $td 'entry.tcl' *> (Join-Path $run 'console.txt')
        $output=Get-Content (Join-Path $run 'console.txt') -Raw
        if($output -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b' -or (Test-Path '*.error.f')){throw "TD $step failed: $run/console.txt"}
        $artifact=if($step -eq 'syn'){Join-Path $run ($project+'_gate.db')}else{Join-Path $run ($project+'.bit')}
        if(-not (Test-Path -LiteralPath $artifact)){throw "TD $step did not produce $artifact"}
        if((Get-Item -LiteralPath $artifact).LastWriteTimeUtc -lt $started){throw "TD $step left a stale artifact: $artifact"}
        Write-Host "PASS $board $step"
        if($step -eq 'phy'){& (Join-Path $PSScriptRoot 'check-reports.ps1') -RunDir $run}
    }finally{Pop-Location}
}
