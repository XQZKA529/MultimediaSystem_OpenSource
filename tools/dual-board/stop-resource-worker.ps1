param(
 [Parameter(Mandatory)][ValidatePattern('^[a-z0-9_]+$')][string]$Name,
 [Parameter(Mandatory)][string]$Reason
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$job=Join-Path $workspace ('build/resource-v1/jobs/'+$Name)
$statusPath=Join-Path $job 'status.json'
$record=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
if($record.state -ne 'running'){throw 'Worker is not running'}
$rootProcess=Get-CimInstance Win32_Process -Filter ('ProcessId='+$record.pid)
if(-not $rootProcess -or $rootProcess.CommandLine -notlike '*resource-worker.ps1*' -or
   $rootProcess.CommandLine -notlike ('*'+$Name+'*')){throw 'Worker identity does not match recorded job'}
$all=@(Get-CimInstance Win32_Process)
$tree=[Collections.Generic.List[object]]::new();$tree.Add($rootProcess)
for($i=0;$i -lt $tree.Count;$i++){
 foreach($child in $all){if($child.ParentProcessId -eq $tree[$i].ProcessId){$tree.Add($child)}}
}
# Freeze orchestration first, then terminate only its verified descendants.
Stop-Process -Id $rootProcess.ProcessId -Force
for($i=$tree.Count-1;$i -ge 1;$i--){
 $expected=$tree[$i]
 $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$expected.ProcessId)
 if($current -and $current.CreationDate -eq $expected.CreationDate){Stop-Process -Id $current.ProcessId -Force -ErrorAction SilentlyContinue}
}
$record.state='stopped';$record.detail=$Reason;$record.updated_utc=[DateTime]::UtcNow.ToString('o')
[IO.File]::WriteAllText($statusPath,($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Host "STOPPED $Name; existing partial logs retained: $Reason"
