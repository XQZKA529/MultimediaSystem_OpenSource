param(
    [ValidatePattern('^[a-z0-9_]+$')][string]$RunTag='slice_optimized',
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
# Reproduce the measured pair. Keep protocol, clocks and signed timing gates.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach($board in @('media','render')){
    $boardRoot=Join-Path $root $board
    foreach($stage in @('syn','phy')){
        if(Test-Path -LiteralPath (Join-Path $boardRoot "Runs/${stage}_$RunTag")){
            throw "Run exists: $board/$stage; choose a fresh RunTag."
        }
    }
}
foreach($board in @('media','render')){
    & (Join-Path $root "$board/build/run.ps1") -Stage syn -RunTag $RunTag -TdRoot $TdRoot
    $seed=if($board -eq 'media'){3}else{5}
    & (Join-Path $PSScriptRoot 'run-area-physical.ps1') -Board $board -SynthesisRunTag $RunTag -RunTag $RunTag -PlaceSeed $seed -TdRoot $TdRoot
}
