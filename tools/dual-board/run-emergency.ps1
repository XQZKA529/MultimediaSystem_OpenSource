param([switch]$SkipRegression,[switch]$ReuseOverlayEvidence)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
    $started=[DateTime]::UtcNow.ToString('o')
    $inputs=[ordered]@{}
    foreach($board in @('media','render')){$inputs[$board]=(& "./$board/build/input-fingerprint.ps1") | ConvertFrom-Json -AsHashtable}
    $records=[Collections.Generic.List[string]]::new()
    foreach($test in @('tb_emergency_controller','tb_emergency_overlay','tb_audio_volume_gain','tb_mix_transition')) {
        if($test -eq 'tb_emergency_overlay' -and $ReuseOverlayEvidence) {
            $stamp=Get-Content -LiteralPath './build/emergency-gpio/frames/overlay-evidence.json' -Raw | ConvertFrom-Json -AsHashtable
            foreach($name in $stamp.inputs.Keys){
                if((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stamp.inputs[$name]){throw "Overlay input changed: $name"}
            }
            foreach($name in $stamp.evidence.Keys){
                if((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $stamp.evidence[$name]){throw "Overlay evidence changed: $name"}
            }
            Write-Host 'PASS reuse byte-identical overlay source, testbench and verified full-frame evidence'
        } else { & ./render/sim/run.ps1 -Test $test }
        $records.Add("render/build/evidence/$test.txt")
    }
    & ./media/sim/run.ps1 -Test tb_emergency_media
    $records.Add('media/build/evidence/tb_emergency_media.txt')
    & ./media/sim/run.ps1 -Test tb_keypad_images
    $records.Add('media/build/evidence/tb_keypad_images.txt')
    & ./media/sim/run.ps1 -Test tb_emergency_integration
    $records.Add('media/build/evidence/tb_emergency_integration.txt')
    & ./media/sim/run.ps1 -Test tb_emergency_integration -EmergencyMono
    $records.Add('media/build/evidence/tb_emergency_integration_mono.txt')
    foreach($case in @('gpio','quick','paused','format','missing','read_error','reentry','empty','disconnect','reset','render_reset','switch','paused_switch','restore_body_error','switch_many','pending_begin','cfg_race')) {
        & ./media/sim/run.ps1 -Test tb_emergency_integration -EmergencyCase $case
        $records.Add("media/build/evidence/tb_emergency_integration_$case.txt")
    }
    & ./tools/dual-board/run-system.ps1 -Test tb_emergency_system -FrameWords 128
    $records.Add('doc/dual-board/evidence/emergency-system.txt')
    if(-not $SkipRegression) {
        foreach($test in @('tb_link','tb_temac_gate','tb_fat_wav_controller','tb_fat_wav_actual','tb_media_sd_boot','tb_settings_menu','tb_bmp_controller','tb_keypad_router','tb_volume_transport','tb_sd_subtitle_controller','tb_sd_subtitle_fat')) {
            & ./media/sim/run.ps1 -Test $test
            $records.Add("media/build/evidence/$test.txt")
        }
        & ./media/sim/run.ps1 -Test tb_fat_wav_controller -ExternalPosition
        $records.Add('media/build/evidence/tb_fat_wav_controller_external_position.txt')
        & ./media/sim/run.ps1 -Test tb_settings_menu -SharedKeys
        $records.Add('media/build/evidence/tb_settings_menu_shared.txt')
        foreach($test in @('tb_link','tb_temac_gate','tb_audio_sink','tb_image_commit','tb_ui_snapshot','tb_text_osd_events','tb_sd_subtitle_view','tb_volume_protocol','tb_frame_read_dual')) {
            & ./render/sim/run.ps1 -Test $test
            $records.Add("render/build/evidence/$test.txt")
        }
        & ./tools/dual-board/run-system.ps1 -Test tb_text_osd_menu
        $records.Add('doc/dual-board/evidence/text-osd-menu-system.txt')
        & ./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleBmp
        $records.Add('doc/dual-board/evidence/audio-system-0-mono0_bmp_scale.txt')
        & ./tools/dual-board/run-system.ps1 -Test tb_audio_system -ScaleBmp -Mono
        $records.Add('doc/dual-board/evidence/audio-system-0-mono1_bmp_scale.txt')
        & ./tools/dual-board/run-system.ps1 -Test tb_sd_subtitle_system -NoFrameExport
        $records.Add('doc/dual-board/evidence/sd-subtitle-system_no_frames.txt')
    }
    & python ./tools/dual-board/audit.py
    if($LASTEXITCODE -ne 0){throw 'Local dependency / baseline audit failed'}
    foreach($board in @('media','render')){
        $current=(& "./$board/build/input-fingerprint.ps1") | ConvertFrom-Json -AsHashtable
        if($current.Count -ne $inputs[$board].Count){throw 'Source set changed during simulation'}
        foreach($name in $current.Keys){if($current[$name] -ne $inputs[$board][$name]){throw "Input changed during simulation: $board/$name"}}
    }
    $evidence=[ordered]@{}
    foreach($name in $records){
        if((Get-Content -LiteralPath $name -Raw) -notmatch '\*\*\* PASS \*\*\*'){throw "Missing PASS evidence: $name"}
        $evidence[$name]=(Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $result=[ordered]@{started_utc=$started;finished_utc=[DateTime]::UtcNow.ToString('o');
        full_regression=(-not $SkipRegression);test_count=$records.Count;inputs=$inputs;evidence=$evidence;hardware_acceptance='pending'}
    $report=if($SkipRegression){'emergency-focused.json'}else{'emergency-regression.json'}
    [IO.File]::WriteAllText((Join-Path $root "doc/dual-board/evidence/$report"),($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Host 'PASS emergency v1 regression (hardware acceptance is separate)'
} finally {Pop-Location}
