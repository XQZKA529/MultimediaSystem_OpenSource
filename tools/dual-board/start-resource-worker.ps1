param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$Name,
    [Parameter(Mandatory)][string]$ActionsJson
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$job=Join-Path $workspace ('build/resource-v1/jobs/'+$Name)
if(Test-Path -LiteralPath $job){throw 'Worker name must be new; existing evidence is immutable'}
$actions=ConvertFrom-Json -InputObject $ActionsJson
foreach($action in @($actions)){
    if(-not $action.program -or -not $action.PSObject.Properties['arguments']){
        throw 'Each action requires program and arguments; refusing an empty invocation.'
    }
}
New-Item -ItemType Directory -Path $job | Out-Null
$config=Join-Path $job 'config.json'
[IO.File]::WriteAllText($config,([ordered]@{workspace=$workspace;actions=@($actions)} | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$program=(Get-Command pwsh -ErrorAction Stop).Source
$worker=Join-Path $PSScriptRoot 'resource-worker.ps1'
$process=Start-Process -FilePath $program -ArgumentList @('-NoProfile','-File',('"'+$worker+'"'),'-ConfigPath',('"'+$config+'"')) `
    -WindowStyle Hidden -WorkingDirectory $workspace -RedirectStandardOutput (Join-Path $job 'stdout.txt') `
    -RedirectStandardError (Join-Path $job 'stderr.txt') -PassThru
Write-Host "STARTED independent worker $Name pid=$($process.Id) status=$job/status.json"
