param([int]$FrameWords=691200,[ValidateSet('tb_system','tb_emergency_system','tb_audio_system','tb_text_osd_menu','tb_sd_subtitle_system')][string]$Test='tb_system',[int]$Scenario=0,[switch]$Mono,[switch]$ScaleBmp,[switch]$ScaleFull,[switch]$VolumeRetry,[switch]$MenuSmoke,[switch]$NoFrameExport,[string]$DesignRoot='',[string]$EvidenceDir='')
$ErrorActionPreference='Stop'
if($EvidenceDir){$EvidenceDir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidenceDir)}
if($NoFrameExport -and $Test -ne 'tb_sd_subtitle_system'){throw 'NoFrameExport requires tb_sd_subtitle_system'}
if($ScaleFull){$ScaleBmp=$true}
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if($DesignRoot){$root=(Resolve-Path -LiteralPath $DesignRoot).Path}
$frozenBoardInputs=@{}
foreach($inputBoard in @('media','render')){
    $frozenBoardInputs[$inputBoard]=((& (Join-Path $root "$inputBoard/build/input-fingerprint.ps1")) | ConvertFrom-Json -AsHashtable)
}
$ms=if($env:MODELSIM_BIN){$env:MODELSIM_BIN}else{'D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'}
$work=Join-Path $env:TEMP ('dual_system_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$renderAlias=Join-Path $work 'render/rtl/link'
New-Item -ItemType Directory -Force $renderAlias | Out-Null
Copy-Item -LiteralPath "$root/render/rtl/pkg" -Destination (Join-Path $work 'render/rtl') -Recurse
Copy-Item -LiteralPath "$root/render/rtl/link/db_crc.vh" -Destination $renderAlias
# Bind the actual render implementation independently. Only module identifiers
# are renamed in temporary simulation copies; production files remain intact.
$renderFiles=@()
foreach($name in @('db_packet_ram','db_async_fifo','db_mac_rx','db_link')){
    $source=Get-Content -LiteralPath "$root/render/rtl/link/$name.v" -Raw
    $source=[regex]::Replace($source,'\b(db_packet_ram|db_async_fifo|db_mac_rx|db_link|db_management_word_fifo|db_rx_header_pipe|db_sequence_hold)\b',{$args[0].Value+'_render'})
    $target=Join-Path $renderAlias ($name+'.v')
    [IO.File]::WriteAllText($target,$source,[Text.UTF8Encoding]::new($false))
    $renderFiles+=$target
}
$files=@('media/rtl/link/db_packet_ram.v','media/rtl/link/db_async_fifo.v','media/rtl/link/db_mac_rx.v','media/rtl/link/db_link.v',
    'media/rtl/seam/db_stream_fifo.v','media/rtl/seam/seam_media.v','render/rtl/seam/seam_render.v','media/sim/tb_link.v','render/rtl/video/mix_alpha_ctrl.v','render/rtl/video/mix_transition_ctrl.v','tools/dual-board/tb_transition_model.v',"tools/dual-board/$Test.v")
if($Test -eq 'tb_sd_subtitle_system'){
    $files+=@('media/rtl/ui/subtitle_ram.v','media/rtl/ui/txt_prefix_parser.v','media/rtl/ui/sd_subtitle_controller.v',
              'media/rtl/storage/storage_service.v','media/rtl/fat/fat32_ro.v','render/rtl/ui/sd_subtitle_view.v',
              'tools/dual-board/tb_sd_subtitle_frame_probe.v','render/rtl/video/contrast_adjust.v','render/rtl/video/error_overlay.v',
              'render/rtl/video/video_stream_reg.v','render/rtl/video/brightness_scale.v','render/rtl/ui/ui_text_overlay.v',
              'render/rtl/ui/text_osd_overlay.v','render/rtl/ui/volume_overlay.v','render/rtl/ui/font_rom.v',
              'render/rtl/ui/audio_osd_overlay.v','render/rtl/ui/osd_paint_text.v','render/rtl/ui/osd_paint_bar.v',
              'render/rtl/ui/osd_paint_icon.v','render/rtl/ui/osd_paint_anim.v')
}
if($Test -eq 'tb_audio_system'){
    $files+=@('media/rtl/audio/fat_wav_controller.v','media/rtl/audio/wav_header_parse.v','media/rtl/audio/wav_pcm_unpack.v',
        'media/rtl/storage/lba_stream.v','render/rtl/seam/db_audio_sink.v','render/rtl/audio/audio_ring_bram.v',
        'render/rtl/audio/wav_play_glue.v','render/rtl/audio/audio_wav_pcm.v')
}
if($Test -eq 'tb_text_osd_menu'){
    $files+=@('media/rtl/clock/key_debounce.v','media/rtl/clock/key_click_decode.v',
        'media/rtl/audio/volume_controller.v','media/rtl/clock/keypad_action_router.v','media/rtl/ui/file_browser.v','media/rtl/ui/settings_menu_text_rom.v',
        'render/rtl/audio/volume_view_cdc.v','render/rtl/audio/audio_volume_gain.v','render/rtl/ui/ui_text_overlay.v','render/rtl/ui/font_rom.v','render/rtl/ui/text_osd_event_router.v',
        'render/rtl/ui/text_osd_store.v','render/rtl/ui/text_osd_controller.v','render/rtl/ui/text_osd_view_cdc.v','render/rtl/ui/text_osd_overlay.v')
}
if($ScaleBmp){
    $FrameWords=if($ScaleFull){691200}else{432}
    $files+=@('tools/dual-board/tb_bmp_network_source.v','media/rtl/image/fat_bmp_controller.v',
        'media/rtl/clock/key_debounce.v','media/rtl/framebuffer/rgb888_word_packer.v',
        'media/rtl/image/bmp_header_parser.v','media/rtl/image/bmp_pixel_unpack.v',
        'media/rtl/image/image_scale_geometry.v','media/rtl/image/image_row_store.v',
        'media/rtl/image/image_scale_nearest.v','media/rtl/image/bmp_image_pipeline.v')
    $oracleArgs=@('--out',$work,'--network-only')
    if($ScaleFull){$oracleArgs+='--full'}
    & python (Join-Path $root 'media/sim/bmp_scale_reference.py') @oracleArgs
    if($LASTEXITCODE -ne 0){throw 'BMP reference generation failed'}
}
$files=@($files | ForEach-Object {Join-Path $root $_})
if($Test -eq 'tb_text_osd_menu'){$files+=@((Join-Path $root 'render/rtl/ui/calendar_clock.v'),(Join-Path $root 'render/rtl/ui/clock_view_cdc.v'))}
$files=$renderFiles+$files
if($Test -eq 'tb_sd_subtitle_system'){
    $hw=Join-Path $work 'subtitle_ram_hw.v'
    $source=(Get-Content "$root/media/rtl/ui/subtitle_ram.v" -Raw).Replace('`ifdef DB_BEHAVIORAL_RAM','`ifdef SUBTITLE_FORCE_BEHAVIORAL_NEVER')
    [IO.File]::WriteAllText($hw,$source,[Text.UTF8Encoding]::new($false))
    $files=@($files | Where-Object {$_ -ne (Join-Path $root 'media/rtl/ui/subtitle_ram.v')})+@($hw)
}
$simTops=@($Test)
if($Test -in @('tb_text_osd_menu','tb_sd_subtitle_system')){
    $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
    $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram32k.v")+$files
    $simTops+='glbl'
}
Push-Location $work
try{
    & (Join-Path $ms 'vlib.exe') work | Out-Null
    # The 32-bit ModelSim compiler can corrupt its heap on the long audio
    # command line. Compile bounded batches into the same work library.
    for($first=0;$first -lt $files.Count;$first+=8){
        $last=[Math]::Min($first+7,$files.Count-1)
        $batch=@($files[$first..$last])
        & (Join-Path $ms 'vlog.exe') '+define+DB_BEHAVIORAL_RAM' "+incdir+$renderAlias" "+incdir+$root/render/sim" "+incdir+$root/render/rtl/ui" "+incdir+$root/media/rtl" "+incdir+$root/media/rtl/link" "+incdir+$root/media/rtl/seam" @batch *>> compile.txt
        if($LASTEXITCODE -ne 0){Get-Content compile.txt;throw 'System compile failed'}
    }
    if($Test -eq 'tb_audio_system'){
        $simParameters=@("-gFRAME_WORDS=$(if($ScaleBmp){$FrameWords}else{128})","-gSCENARIO=$Scenario","-gMONO=$([int]$Mono.IsPresent)")
    }elseif($Test -eq 'tb_sd_subtitle_system'){$simParameters=@("-gEXPORT_FRAMES=$([int](-not $NoFrameExport.IsPresent))")}elseif($Test -eq 'tb_text_osd_menu'){$simParameters=@("-gRETRY_TEST=$([int]$VolumeRetry.IsPresent)","-gMENU_SMOKE=$([int]$MenuSmoke.IsPresent)")}else{$simParameters=@("-gFRAME_WORDS=$FrameWords")}
    if($ScaleBmp){$simParameters+='-gSCALE_BMP=1'}
    if($ScaleFull){$simParameters+=@('-gBMP_W=1280','-gBMP_H=720')}
    & (Join-Path $ms 'vsim.exe') -c @simParameters "+AA_ATLAS=$root/render/sim/aa-font/atlas.hex" "+AA_DIAG=$root/render/sim/aa-font/diagnostic.hex" -do 'run -all; quit -f' @simTops *> simulation.txt
    $out=Get-Content simulation.txt -Raw
    if($out -notmatch '\*\*\* PASS \*\*\*'){Write-Host $out;throw "System simulation failed: $work"}
    if(-not $EvidenceDir){$EvidenceDir=Join-Path $root 'doc/dual-board/evidence'}
    New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
    $evidence=if($Test -eq 'tb_emergency_system'){'emergency-system'}elseif($Test -eq 'tb_audio_system'){"audio-system-$Scenario-mono$([int]$Mono.IsPresent)"}elseif($Test -eq 'tb_sd_subtitle_system'){'sd-subtitle-system'}elseif($Test -eq 'tb_text_osd_menu'){'text-osd-menu-system'}else{"system-$FrameWords"}
    if($MenuSmoke){$evidence+='_smoke'}
    if($VolumeRetry){$evidence+='_volume_retry'}
    if($NoFrameExport){$evidence+='_no_frames'}
    if($ScaleBmp){$evidence+='_bmp_scale'}
    if($ScaleFull){$evidence+='_720p'}
    [IO.File]::WriteAllText((Join-Path $EvidenceDir ($evidence+'.txt')),[regex]::Replace($out,'(?m)[ \t]+(?=\r?$)',''))
    foreach($inputBoard in @('media','render')){
        $afterInputs=((& (Join-Path $root "$inputBoard/build/input-fingerprint.ps1")) | ConvertFrom-Json -AsHashtable)
        $beforeInputs=$frozenBoardInputs[$inputBoard]
        if($afterInputs.Count -ne $beforeInputs.Count){throw "Design changed during simulation: $inputBoard"}
        foreach($inputName in $beforeInputs.Keys){if($afterInputs[$inputName] -ne $beforeInputs[$inputName]){throw "Simulation input changed: $inputBoard/$inputName"}}
    }
    $designInputs=[ordered]@{
        media=$frozenBoardInputs['media'];render=$frozenBoardInputs['render']
        test=$Test; frameWords=$FrameWords; scenario=$Scenario; mono=$Mono.IsPresent
        scaleBmp=$ScaleBmp.IsPresent; scaleFull=$ScaleFull.IsPresent; volumeRetry=$VolumeRetry.IsPresent
    }
    $simulationInputs=[ordered]@{}
    foreach($inputFile in (@($files)+@((Join-Path $root 'render/sim/aa-font/atlas.hex'),(Join-Path $root 'render/sim/aa-font/diagnostic.hex')))){
        if(Test-Path -LiteralPath $inputFile){$simulationInputs[$inputFile]=(Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $designInputs['simulationFiles']=$simulationInputs
    [IO.File]::WriteAllText((Join-Path $EvidenceDir ($evidence+'.inputs.json')),($designInputs | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if($Test -eq 'tb_sd_subtitle_system' -and -not $NoFrameExport){
        $frameDir=Join-Path $root 'build/sd-subtitle-sim/frames'
        New-Item -ItemType Directory -Force $frameDir | Out-Null
        Get-ChildItem -LiteralPath $work -Filter 'sd_subtitle_*_frame.ppm' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $frameDir -Force
        }
    }
    Write-Host ($out | Select-String -Pattern '.*\*\*\* PASS.*' | ForEach-Object {$_.Matches.Value})
}finally{Pop-Location}
