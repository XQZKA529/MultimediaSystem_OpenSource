param(
    [string]$CheckpointRoot=$PSScriptRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [string]$TdRoot='D:/AnLu_FPGA_environment',
    [switch]$RunRegressions,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$checkpoint=(Resolve-Path -LiteralPath $CheckpointRoot).Path
$output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
if(Test-Path -LiteralPath $output){throw 'Reproduction output must be a new directory.'}
if($output.StartsWith($checkpoint.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw 'Keep the frozen checkpoint unchanged: choose an output outside its directory.'
}
$manifest=Get-Content -LiteralPath (Join-Path $checkpoint 'manifest.json') -Raw | ConvertFrom-Json
if($manifest.status -ne 'EXPERIMENTAL_CHECKPOINT'){throw 'Not a resource experimental checkpoint.'}
New-Item -ItemType Directory -Path $output | Out-Null
$source=Join-Path $output 'source'
Copy-Item -LiteralPath (Join-Path $checkpoint 'source') -Destination $source -Recurse
$scripts=Join-Path $source 'tools/dual-board'
foreach($board in @('media','render')){
    $boardRoot=Join-Path $source $board
    # The copied relative input hashes must match the measured source exactly.
    $expected=Get-Content -LiteralPath (Join-Path $checkpoint "evidence/$board/inputs.json") -Raw | ConvertFrom-Json -AsHashtable
    $actual=(& (Join-Path $boardRoot 'build/input-fingerprint.ps1')) | ConvertFrom-Json -AsHashtable
    if($actual.Count -ne $expected.Count){throw "$board source set differs from checkpoint."}
    foreach($name in $expected.Keys){if($actual[$name] -ne $expected[$name]){throw "$board input changed: $name"}}
    $settings=Get-Content -LiteralPath (Join-Path $checkpoint "evidence/$board/settings.cfg") -Raw
    $seedMatch=[regex]::Match($settings,'\bplace seed (\d+)\b')
    $mapMatch=[regex]::Match($settings,'\bgate map_mode (\w+)\b')
    $fsmMatch=[regex]::Match($settings,'\brtl infer_fsm (\w+)\b')
    if(!$seedMatch.Success -or !$mapMatch.Success){throw 'Missing saved implementation settings.'}
    $seed=[int]$seedMatch.Groups[1].Value
    $areaEffort=if($settings -match '\bgate add_map_lut_struct high\b'){'high'}else{'auto'}
    if($ValidateOnly){Write-Host "VALIDATED $board inputs and saved seed=$seed mapping=$($mapMatch.Groups[1].Value) area=$areaEffort";continue}
    $tag='checkpoint_reproduce_'+$board
    $synthesis=@{Stage='syn';RunTag=$tag;TdRoot=$TdRoot;MapMode=$mapMatch.Groups[1].Value}
    # Render's original synthesis entry has no FSM/area overrides. Only pass
    # explicit options that exist in the measured configuration and entry.
    $entry=Join-Path $boardRoot 'build/run.ps1'
    $supported=(Get-Command $entry).Parameters
    if($fsmMatch.Success){
        if(!$supported.ContainsKey('InferFsm')){throw 'Saved FSM override unsupported by archived entry.'}
        $synthesis.InferFsm=$fsmMatch.Groups[1].Value
    }
    if($supported.ContainsKey('AreaEffort')){$synthesis.AreaEffort=$areaEffort}
    elseif($areaEffort -ne 'auto'){throw 'Saved area override unsupported by archived entry.'}
    & $entry @synthesis
    if($LASTEXITCODE -ne 0){throw "$board synthesis failed."}
    $physical=@{Board=$board;BoardRoot=$boardRoot;SynthesisRunTag=$tag;RunTag=$tag;PlaceSeed=$seed;TdRoot=$TdRoot}
    if($settings -match '\bplace timing_driven_mode off\b'){$physical.AreaPlacement=$true}
    $physical.PhysicalEffort=if($settings -match '\bplace effort high\b'){'high'}else{'medium'}
    if($settings -match '\bplace post_place_opt off\b'){$physical.SkipPostPlaceOpt=$true}
    $relax=[regex]::Match($settings,'\bplace relaxation ([0-9.]+)\b')
    if($relax.Success){$physical.PlaceRelaxation=[double]::Parse($relax.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
    else{$physical.NativeRelaxation=$true}
    & (Join-Path $scripts 'run-resource-physical.ps1') @physical
    if($LASTEXITCODE -ne 0){throw "$board implementation failed."}
    & (Join-Path $scripts 'generate-resource-trial.ps1') -Board $board -BoardRoot $boardRoot -RunTag $tag -TdRoot $TdRoot
    if($LASTEXITCODE -ne 0){throw "$board experimental bit generation failed."}
}
if($RunRegressions -and !$ValidateOnly){
    & (Join-Path $scripts 'run-system.ps1') -DesignRoot $source -EvidenceDir (Join-Path $output 'regressions/full-system') -Test tb_system -ScaleFull
    if($LASTEXITCODE -ne 0){throw 'Full 720p regression failed.'}
    & (Join-Path $scripts 'run-system.ps1') -DesignRoot $source -EvidenceDir (Join-Path $output 'regressions/audio-system') -Test tb_audio_system -ScaleBmp
    if($LASTEXITCODE -ne 0){throw 'Audio regression failed.'}
    & (Join-Path $scripts 'run-system.ps1') -DesignRoot $source -EvidenceDir (Join-Path $output 'regressions/subtitle-system') -Test tb_sd_subtitle_system -NoFrameExport
    if($LASTEXITCODE -ne 0){throw 'Subtitle regression failed.'}
}
if($ValidateOnly){Write-Host 'Validated frozen inputs and replay settings; no synthesis, bit generation or simulation was run.'}
else{Write-Host 'Reproduced experimental builds. Inspect their final post-hold reports; this does not certify the 90% target or formal qualification.'}
