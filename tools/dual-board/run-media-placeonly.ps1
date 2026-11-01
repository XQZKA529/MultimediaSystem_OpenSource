param(
    [Parameter(Mandatory)][ValidatePattern('^syn_[a-z0-9_]+$')][string]$SynthesisRun,
    [Parameter(Mandatory)][ValidatePattern('^phy_[a-z0-9_]+$')][string]$PhysicalRun,
    [ValidateRange(0,2147483647)][int]$PlaceSeed=4,
    [ValidateSet('normal','routability')][string]$RouteEffort='routability',
    [string]$TdRoot=$env:TD_ROOT
)
$ErrorActionPreference='Stop'
$workspace=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$board=Join-Path $workspace 'media'
$runs=Join-Path $board 'Runs'
$parent=Join-Path $runs $SynthesisRun
$run=Join-Path $runs $PhysicalRun
if(Test-Path -LiteralPath $run){throw "Use a new PhysicalRun name: $run"}
foreach($file in @('settings.cfg','inputs.json','MultimediaSystem_media_gate.db')){
    if(-not (Test-Path -LiteralPath (Join-Path $parent $file))){throw "Missing synthesis artifact: $parent/$file"}
}
if(-not $TdRoot){$TdRoot='D:/AnLu_FPGA_environment'}
$td=Join-Path $TdRoot 'bin/td_commands_prompt.exe'
if(-not (Test-Path -LiteralPath $td)){throw "TD executable not found: $td"}
$synSettings=Get-Content -LiteralPath (Join-Path $parent 'settings.cfg') -Raw
$gatePath=Join-Path $parent 'MultimediaSystem_media_gate.db'
$gateHash=(Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).Hash.ToLowerInvariant()
$match=[regex]::Match($synSettings,'(?m)^set synWildParams \{([^\r\n]*)\}')
if(-not $match.Success){throw 'Missing synthesis parameters'}
$physicalParams="route effort $RouteEffort route fix_hold on place seed $PlaceSeed place effort high place opt_timing high place logic_level_opt on place aggressive_opt 20 place aggr_neighbor_dist 5 place enhanced_beeline_opt 3 place timing_driven_mode on place shifter_opt on place crit_path_opt off place post_place_opt high route post_route_opt high"
$config=@($synSettings -split '\r?\n' | Where-Object {
    $_ -and $_ -notmatch '^set (run_type|synWildParams|start_step|end_step|parent|arr_filter|drHoldFix)\b'
})
$config+=@('set run_type phy',"set synWildParams {$($match.Groups[1].Value) $physicalParams}",
    'set start_step opt_place','set end_step opt_place',"set parent ../$SynthesisRun",'set arr_filter false','set drHoldFix on')
New-Item -ItemType Directory -Path $run | Out-Null
& (Join-Path $board 'build/input-fingerprint.ps1') -Output (Join-Path $run 'inputs.json')
if((Get-Content -LiteralPath (Join-Path $parent 'inputs.json') -Raw) -ne
   (Get-Content -LiteralPath (Join-Path $run 'inputs.json') -Raw)){
    throw 'Inputs changed since synthesis; rebuild synthesis before placement.'
}
$boardPath=$board.Replace('\','/')
$runPath=$run.Replace('\','/')
$entry="source ./settings.cfg`ncd {$boardPath}`nopen_project MultimediaSystem_media.al -noanalyze`ncd {$runPath}`nset singleRun 1`nsource {$boardPath/build/MyFlow.tcl}`n"
[IO.File]::WriteAllText((Join-Path $run 'settings.cfg'),($config -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $run 'entry.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try {
    $started=[DateTime]::UtcNow
    & $td 'entry.tcl' *> (Join-Path $run 'console.txt')
    $exitCode=$LASTEXITCODE
}finally{Pop-Location}
$log=Get-Content -LiteralPath (Join-Path $run 'console.txt') -Raw
if($exitCode -ne 0 -or $log -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b' -or
   (Test-Path -LiteralPath (Join-Path $run '.opt_place.error.f'))){throw "Placement failed: $run/console.txt"}
$report=Join-Path $run 'place.qor'
$database=Join-Path $run 'MultimediaSystem_media_place.db'
if(-not (Test-Path -LiteralPath $report) -or -not (Test-Path -LiteralPath $database)){
    throw 'Placement did not produce the expected report/database.'
}
if((Get-Item -LiteralPath $database).LastWriteTimeUtc -lt $started){throw 'Stale placement database'}
if(-not (Test-Path -LiteralPath (Join-Path $run '.opt_place.end.f'))){throw 'Placement did not finish cleanly'}
if((Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $gateHash -or
   (Get-Content -LiteralPath (Join-Path $parent 'settings.cfg') -Raw) -ne $synSettings){
    throw 'Parent synthesis database/settings changed during placement.'
}
$recorded=Get-Content -LiteralPath (Join-Path $run 'inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$current=(& (Join-Path $board 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
if($recorded.Count -ne $current.Count){throw 'Source set changed during placement.'}
foreach($path in $recorded.Keys){
    if($recorded[$path] -ne $current[$path]){throw "Input changed during placement: $path"}
}
$qor=Get-Content -LiteralPath $report -Raw
function ReadMetric([string]$name){
    $value=[regex]::Match($qor,[regex]::Escape($name)+'\s*\|\s*(-?[0-9.]+)')
    if(-not $value.Success){throw "Missing QoR metric: $name"}
    return [double]::Parse($value.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
}
$slices=ReadMetric '#slices'
$setup=ReadMetric 'Setup WNS'
$hold=ReadMetric 'Hold WNS'
$setupViolations=ReadMetric 'Num of violated S-EP'
$holdViolations=ReadMetric 'Num of violated H-EP'
$timingMet=$setup -gt 0 -and $hold -gt 0 -and $setupViolations -eq 0 -and $holdViolations -eq 0
$summary=[ordered]@{synthesis_run=$SynthesisRun;synthesis_gate_sha256=$gateHash;
    physical_run=$PhysicalRun;stage='place-only';place_seed=$PlaceSeed;route_effort=$RouteEffort;
    slices=[int]$slices;slice_percent=(ReadMetric 'slices percentage');
    setup_wns_ns=$setup/1000;hold_wns_ns=$hold/1000;timing_met=$timingMet;
    area95_met=($slices -le 9310);area95_and_place_timing_met=($slices -le 9310 -and $timingMet);
    routed_timing_verified=$false}
$json=$summary | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $run 'place-summary.json'),$json,[Text.UTF8Encoding]::new($false))
Write-Output $json
