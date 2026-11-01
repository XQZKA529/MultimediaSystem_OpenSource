param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$configuration=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$jobDirectory=Split-Path -Parent $ConfigPath
$statusPath=Join-Path $jobDirectory 'status.json'
$started=[DateTime]::UtcNow.ToString('o')
function Save-WorkerState([string]$State,[int]$Action,[string]$Detail=''){
    $record=[ordered]@{state=$State;pid=$PID;started_utc=$started;updated_utc=[DateTime]::UtcNow.ToString('o');action=$Action;detail=$Detail}
    $temporary=$statusPath+'.tmp'
    [IO.File]::WriteAllText($temporary,($record | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$statusPath,$true)
}
Set-Location -LiteralPath $configuration.workspace
$actionIndex=0
try{
    Save-WorkerState 'running' 0
    foreach($action in $configuration.actions){
        Save-WorkerState 'running' $actionIndex $action.program
        $launch=[Diagnostics.ProcessStartInfo]::new()
        $launch.FileName=$action.program
        $launch.WorkingDirectory=$configuration.workspace
        $launch.UseShellExecute=$false
        $launch.RedirectStandardInput=$true
        foreach($argument in $action.arguments){$launch.ArgumentList.Add([string]$argument)}
        $child=[Diagnostics.Process]::Start($launch)
        # TD returns to its CLI after a flow unless stdin reaches EOF. A hidden
        # console otherwise leaves completed native runs waiting indefinitely.
        $child.StandardInput.Close()
        $child.WaitForExit()
        if($child.ExitCode -ne 0){throw "Action returned exit code $($child.ExitCode)"}
        $actionIndex++
    }
    Save-WorkerState 'complete' $actionIndex
}catch{
    Save-WorkerState 'failed' $actionIndex $_.Exception.Message
    Write-Error $_ -ErrorAction Continue
    exit 1
}
