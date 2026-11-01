# One-time, explicitly scoped cleanup of the closed 2026-10-16 experiments.
# Keep checkpoint 10 immutable. Never follow candidate directory links.
#Requires -Version 7.0
param([switch]$Apply)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build=(Resolve-Path -LiteralPath (Join-Path $workspace 'build')).Path
$resource=Join-Path $build 'resource-v1'
$zip=Join-Path $resource 'resource_trial_checkpoint_10.zip'
if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne
   'b17aebe3f7de4c294c56f2bf50960a3ab2cc90bd332ba05d35bdd9d00d83c5ac'){
    throw 'Final checkpoint hash differs; refusing cleanup.'
}
$keepNames=@('base','tables','jobs','media_rgb_packer_unreset','render_audio_compact9','render_osd_cell32_dsp')
$targets=[Collections.Generic.List[string]]::new()
foreach($item in Get-ChildItem -LiteralPath $resource -Directory){
    if($item.Name -notin $keepNames){$targets.Add($item.FullName)}
}
foreach($item in Get-ChildItem -LiteralPath $resource -File){
    if($item.Name -match '^resource_trial_checkpoint_[1-9]\.zip$' -or
       $item.Name -in @('manifest.json','EXPERIMENT.md','MultimediaSystem_media_RESOURCE_TRIAL.bit','MultimediaSystem_render_RESOURCE_TRIAL.bit')){
        $targets.Add($item.FullName)
    }
}
# The historical GPIO packager still refers to this request-mux physical run.
$oldCandidates=Join-Path $build 'emergency-v1/candidates'
$oldKeep=Join-Path $oldCandidates 'request_mux/media/Runs/phy_emergency_request3'
function Select-Obsolete([string]$Folder){
    foreach($item in Get-ChildItem -LiteralPath $Folder -Force){
        if($item.FullName -eq $oldKeep){continue}
        if($oldKeep.StartsWith($item.FullName.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
            Select-Obsolete $item.FullName
        }else{$targets.Add($item.FullName)}
    }
}
Select-Obsolete $oldCandidates
# Check every final absolute deletion target before any recursive removal.
foreach($target in $targets){
    $full=[IO.Path]::GetFullPath($target)
    if(-not $full.StartsWith($build.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw "Deletion target escaped build: $full"
    }
    if($full -eq $build -or $full -eq $resource -or $full -eq $oldCandidates){throw 'Unsafe broad target'}
}
$plan=Join-Path $build 'cleanup-plan-2026-10-16.json'
[IO.File]::WriteAllText($plan,(@{targets=@($targets);checkpoint_sha256=(Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant();apply=[bool]$Apply}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Host "Checked $($targets.Count) absolute targets under $build; plan: $plan"
if(-not $Apply){return}
$log=[Collections.Generic.List[object]]::new()
foreach($target in $targets){
    if(-not(Test-Path -LiteralPath $target)){continue}
    $item=Get-Item -LiteralPath $target -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
        Remove-Item -LiteralPath $target -Force
    }else{
        # Remove links themselves first, without ever traversing their targets.
        if($item.PSIsContainer){
            $links=@(Get-ChildItem -LiteralPath $target -Recurse -Force |
                     Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
            foreach($link in $links){Remove-Item -LiteralPath $link.FullName -Force}
        }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    $log.Add(@{path=$target;removed=(-not(Test-Path -LiteralPath $target))})
    Write-Host "Removed: $target"
}
[IO.File]::WriteAllText((Join-Path $build 'cleanup-result-2026-10-16.json'),(@{removed=@($log);completed_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Host 'PASS: scoped obsolete experiment cleanup completed.'
