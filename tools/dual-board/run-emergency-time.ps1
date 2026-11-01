param([switch]$SkipFrames)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work=Join-Path $root 'build/emergency-time-v1'
$evidence=Join-Path $work 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$records=[Collections.Generic.List[string]]::new()
$inputs=[ordered]@{}
foreach($board in @('media','render')){$inputs[$board]=(& "$root/$board/build/input-fingerprint.ps1") | ConvertFrom-Json -AsHashtable}
function Save-Log([string]$source,[string]$name){
    $target=Join-Path $evidence ($name+'.txt')
    if([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}
    if((Get-Content -LiteralPath $target -Raw) -notmatch '\*\*\* PASS \*\*\*'){throw "Missing PASS: $target"}
    $records.Add($name+'.txt')
}
function Run-Render([string]$test){
    & "$root/render/sim/run.ps1" -Test $test -EvidenceDir $evidence -FrameDir (Join-Path $work 'frames')
    Save-Log (Join-Path $evidence ($test+'.txt')) $test
}
function Run-Media([string]$test,[hashtable]$options=@{},[string]$suffix=''){
    & "$root/media/sim/run.ps1" -Test $test @options
    Save-Log "$root/media/build/evidence/$test$suffix.txt" ('media_'+$test+$suffix)
}
function Run-System([string]$test,[hashtable]$options,[string]$log){
    & "$root/tools/dual-board/run-system.ps1" -Test $test @options
    Save-Log "$root/doc/dual-board/evidence/$log.txt" $log
}
Push-Location $root
try{
    foreach($test in @('tb_emergency_timestamp','tb_emergency_controller','tb_calendar_clock','tb_clock_view_cdc','tb_clock_events','tb_audio_volume_gain','tb_mix_transition')){Run-Render $test}
    if(-not $SkipFrames){Run-Render 'tb_emergency_overlay';Run-Render 'tb_clock_overlay'}
    Run-Media 'tb_emergency_media'
    Run-Media 'tb_keypad_images'
    Run-Media 'tb_emergency_integration'
    Run-Media 'tb_emergency_integration' @{EmergencyMono=$true} '_mono'
    foreach($case in @('gpio','quick','paused','format','missing','read_error','reentry','empty','disconnect','reset','render_reset','switch','paused_switch','restore_body_error','switch_many','pending_begin','cfg_race')){
        Run-Media 'tb_emergency_integration' @{EmergencyCase=$case} ('_'+$case)
    }
    Run-System 'tb_emergency_system' @{FrameWords=128} 'emergency-system'
    foreach($test in @('tb_link','tb_temac_gate','tb_fat_wav_controller','tb_fat_wav_actual','tb_media_sd_boot','tb_settings_menu','tb_bmp_controller','tb_keypad_router','tb_volume_transport','tb_sd_subtitle_controller','tb_sd_subtitle_fat')){Run-Media $test}
    Run-Media 'tb_fat_wav_controller' @{ExternalPosition=$true} '_external_position'
    Run-Media 'tb_settings_menu' @{SharedKeys=$true} '_shared'
    foreach($test in @('tb_link','tb_temac_gate','tb_audio_sink','tb_image_commit','tb_ui_snapshot','tb_text_osd_events','tb_sd_subtitle_view','tb_volume_protocol','tb_frame_read_dual')){Run-Render $test}
    Run-System 'tb_text_osd_menu' @{} 'text-osd-menu-system'
    Run-System 'tb_audio_system' @{ScaleBmp=$true} 'audio-system-0-mono0_bmp_scale'
    Run-System 'tb_audio_system' @{ScaleBmp=$true;Mono=$true} 'audio-system-0-mono1_bmp_scale'
    Run-System 'tb_sd_subtitle_system' @{NoFrameExport=$true} 'sd-subtitle-system_no_frames'
    # Full-resolution image transport retains the clock receiver fix.
    Run-System 'tb_system' @{ScaleFull=$true} 'system-691200_bmp_scale_720p'
    & python "$root/tools/dual-board/audit.py"
    if($LASTEXITCODE -ne 0){throw 'Dependency/baseline audit failed'}
    foreach($board in @('media','render')){
        $current=(& "$root/$board/build/input-fingerprint.ps1") | ConvertFrom-Json -AsHashtable
        if($current.Count -ne $inputs[$board].Count){throw 'Source set changed during regression'}
        foreach($name in $current.Keys){if($current[$name] -ne $inputs[$board][$name]){throw "Source changed: $board/$name"}}
    }
    $hashes=[ordered]@{}
    foreach($name in $records){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $evidence $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
    $result=[ordered]@{test_count=$records.Count;frames_executed=(-not $SkipFrames);inputs=$inputs;evidence=$hashes;hardware_acceptance='pending'}
    [IO.File]::WriteAllText((Join-Path $work 'regression.json'),($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Host "PASS emergency timestamp regression: $($records.Count) executions"
}finally{Pop-Location}
