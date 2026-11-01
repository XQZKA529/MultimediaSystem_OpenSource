param(
    [Parameter(Mandatory)][ValidateSet('media','render')][string]$Board,
    [Parameter(Mandatory)][string]$BoardRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$RunTag,
    [string]$TdRoot='D:/AnLu_FPGA_environment'
)
# Experimental entry only. Production MyFlow/qualification remain unchanged.
$ErrorActionPreference='Stop'
$BoardRoot=(Resolve-Path -LiteralPath $BoardRoot).Path
$run=Join-Path $BoardRoot ('Runs/phy_'+$RunTag)
& python (Join-Path $PSScriptRoot 'resource_experiment.py') report --board $Board --run $run
if($LASTEXITCODE -ne 0){throw 'Source fingerprint or final report validation failed'}
$report=Get-Content -LiteralPath (Join-Path $run 'resource-experiment.json') -Raw | ConvertFrom-Json
if(-not $report.experiment_pass){throw ('Experimental acceptance failed: '+($report.rejection_reasons -join '; '))}
$project="MultimediaSystem_$Board"
$db=Join-Path $run ($project+'_pr.db')
if(-not(Test-Path -LiteralPath $db)){throw 'Missing routed database'}
$bit=Join-Path $run ($project+'_RESOURCE_TRIAL.bit')
if(Test-Path -LiteralPath $bit){throw 'Trial bit already exists'}
$entry=@"
# RESOURCE TRIAL: this is not production qualification.
import_device eagle_s20.db -package EG4S20BG256
import_db {$($db.Replace('\','/'))}
bitgen -bit ${project}_RESOURCE_TRIAL.bit
export_bitgen_param -file resource_trial_bitgen_param.txt
exit
"@
[IO.File]::WriteAllText((Join-Path $run 'generate-resource-trial.tcl'),$entry,[Text.UTF8Encoding]::new($false))
Push-Location $run
try{
    & (Join-Path $TdRoot 'bin/td_commands_prompt.exe') 'generate-resource-trial.tcl' *> 'resource-trial-bitgen.txt'
    $output=Get-Content -LiteralPath 'resource-trial-bitgen.txt' -Raw
    if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $bit) -or $output -match '(?m)^[A-Z]+-[0-9]+\s+(ERROR|FATAL)\b'){
        throw 'Experimental bit generation failed'
    }
}finally{Pop-Location}
& python (Join-Path $PSScriptRoot 'resource_experiment.py') report --board $Board --run $run
if($LASTEXITCODE -ne 0){throw 'Final bit/source evidence failed'}
Write-Host "GENERATED EXPERIMENTAL BIT: $bit"
