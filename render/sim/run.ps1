param([string]$Test='tb_link',[string]$FontGateNetlist='',[int]$UiCase=1,[int]$ClockCase=-1,[string]$EvidenceDir='',[switch]$PhysicalSubtitleRam,[switch]$PhysicalOverlayRam,[string]$FrameDir='')
$ErrorActionPreference='Stop'
$board=Split-Path -Parent $PSScriptRoot
if(-not $EvidenceDir){$EvidenceDir=Join-Path $board 'build/evidence'}
$EvidenceDir=[IO.Path]::GetFullPath($EvidenceDir)
if($FontGateNetlist){
    if($Test -ne 'tb_font_rom'){throw 'FontGateNetlist applies only to tb_font_rom'}
    $FontGateNetlist=(Resolve-Path -LiteralPath $FontGateNetlist).Path
}
$ms=if($env:MODELSIM_BIN){$env:MODELSIM_BIN}else{'D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'}
$tag=([Guid]::NewGuid().ToString('N'))
$work=Join-Path $env:TEMP ('dual_board_'+$tag)
New-Item -ItemType Directory -Path $work | Out-Null
Push-Location $work
try {
    & (Join-Path $ms 'vlib.exe') work | Out-Null
    $groups=@{
        tb_emergency_timestamp=@('ui/calendar_clock.v','emergency/emergency_inputs.v','emergency/emergency_view_cdc.v','emergency/emergency_overlay.v')
        tb_calendar_clock=@('ui/calendar_clock.v')
        tb_clock_view_cdc=@('ui/clock_view_cdc.v')
        tb_clock_events=@('ui/text_osd_event_router.v','ui/calendar_clock.v')
        tb_clock_overlay=@('ui/clock_overlay.v','ui/volume_overlay.v','ui/font_rom.v','emergency/emergency_overlay.v','video/error_overlay.v')
        tb_emergency_overlay=@('emergency/emergency_overlay.v')
        tb_emergency_controller=@('emergency/emergency_controller.v','emergency/emergency_inputs.v','emergency/emergency_view_cdc.v')
        tb_sd_subtitle_view=@('ui/subtitle_ram.v','ui/sd_subtitle_view.v')
        tb_volume_text_pipeline=@('ui/text_osd_overlay.v','ui/volume_overlay.v','ui/font_rom.v')
        tb_volume_protocol=@('seam/seam_render.v')
        tb_audio_volume_gain=@('audio/audio_volume_gain.v')
        tb_volume_view_cdc=@('audio/volume_view_cdc.v')
        tb_volume_overlay=@('ui/volume_overlay.v','ui/volume_hint_controller.v','ui/font_rom.v')
        tb_font_rom=@('ui/font_rom.v','ui/osd_paint_text.v')
        tb_text_osd_controller=@('ui/text_osd_controller.v')
        tb_text_osd_events=@('driver/keypad_event_encoder.v','ui/text_osd_event_router.v','ui/text_osd_controller.v')
        tb_text_osd_cdc=@('ui/text_osd_view_cdc.v')
        tb_text_osd_overlay=@('ui/text_osd_overlay.v','ui/font_rom.v')
        tb_text_osd_scroll=@('ui/text_osd_overlay.v')
        tb_tm1650_keypad=@('driver/tm1650_keypad.v')
        tb_keypad_events=@('driver/keypad_event_encoder.v')
        tb_contrast_adjust=@('video/contrast_adjust.v')
        tb_saturation_adjust=@('video/saturation_adjust.v')
        tb_goertzel_height=@('fft/audio_fft_osd.v')
        tb_image_contrast=@('video/contrast_adjust.v','video/saturation_adjust.v','video/error_overlay.v','video/video_stream_reg.v','ui/ui_text_overlay.v','ui/font_rom.v','ui/audio_osd_overlay.v','ui/osd_paint_text.v','ui/osd_paint_bar.v','ui/osd_paint_icon.v','ui/osd_paint_anim.v','ui/text_osd_overlay.v','video/brightness_scale.v')
        tb_brightness_scale=@('video/brightness_scale.v')
        tb_ddcci_brightness=@('driver/ddc_i2c_master.v','driver/ddcci_brightness.v')
        tb_sdram_read_contract=@('framebuffer/frame_fifo_read_dual.v','sdram/sdram.v','sdram/sdr_as_ram.enc.v','sdram/sdr_init_ref.enc.v','sdram/sdr_wrrd.enc.v')
        tb_phy_status=@('link/db_ethernet.v')
        tb_rx_clk_buf=@('link/vendor/rgmii_interface.v')
        tb_error_overlay=@('video/error_overlay.v')
        tb_link=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_temac_gate=@('link/db_ethernet.v','link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_link_keepalive=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_session_stability=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_image_commit=@('seam/seam_render.v')
        tb_ui_snapshot=@('seam/seam_render.v')
        tb_frame_vflip=@('framebuffer/frame_fifo_write.v')
        tb_frame_abort=@('framebuffer/frame_fifo_write.v')
        tb_frame_read_dual=@('framebuffer/frame_fifo_read_dual.v','framebuffer/afifo_32_16_256.v','framebuffer/rgb888_word_reader.v','video/pixel_mixer.v','video/video_stream_reg.v','framebuffer/sdram_app_arb.v','sdram/sdram.v','sdram/sdr_as_ram.enc.v','sdram/sdr_init_ref.enc.v','sdram/sdr_wrrd.enc.v')
        tb_pixel_mixer=@('video/pixel_mixer.v')
        tb_image_overlay_64=@('ui/image_overlay_64.v')
        tb_overlay_protocol=@('seam/seam_render.v','ui/image_overlay_64.v')
        tb_mix_alpha=@('video/mix_alpha_ctrl.v')
        tb_mix_transition=@('video/mix_alpha_ctrl.v','video/mix_transition_ctrl.v')
        tb_audio_sink=@('seam/db_audio_sink.v','audio/audio_ring_bram.v','audio/wav_play_glue.v','audio/audio_wav_pcm.v')
        tb_audio_osd_layout=@('ui/audio_osd_overlay.v','ui/osd_paint_text.v','ui/osd_paint_bar.v','ui/osd_paint_icon.v','ui/osd_paint_anim.v','ui/font_rom.v','ui/clock_overlay.v')
        tb_ui_values=@('ui/ui_text_overlay.v','ui/font_rom.v')
        tb_ui_text_overlay=@('ui/ui_text_overlay.v','ui/font_rom.v')
        tb_ui_frame_ppm=@('video/saturation_adjust.v','ui/ui_text_overlay.v','ui/font_rom.v','ui/clock_overlay.v')
        tb_text_osd_frame_ppm=@('video/contrast_adjust.v','video/error_overlay.v','video/video_stream_reg.v','video/brightness_scale.v','ui/ui_text_overlay.v','ui/text_osd_overlay.v','ui/volume_overlay.v','ui/font_rom.v','ui/audio_osd_overlay.v','ui/osd_paint_text.v','ui/osd_paint_bar.v','ui/osd_paint_icon.v','ui/osd_paint_anim.v')
    }
    foreach($textTest in @('tb_text_osd_controller','tb_text_osd_events','tb_text_osd_cdc')){$groups[$textTest]+='ui/text_osd_ram.v'}
    $groups.tb_text_osd_frame_ppm+=@('ui/clock_overlay.v','emergency/emergency_overlay.v')
    $groups.tb_text_osd_pipeline=$groups.tb_image_contrast
    if(-not $groups.ContainsKey($Test)){throw "Unknown test $Test"}
    if($groups[$Test] -contains 'render_core.v'){$groups[$Test]+=@('ui/subtitle_ram.v','ui/sd_subtitle_view.v')}
    $files=@($groups[$Test] | ForEach-Object {"$board/rtl/$_"})+@("$board/sim/$Test.v")
    if($FontGateNetlist){$files=@($files | Where-Object {$_ -ne "$board/rtl/ui/font_rom.v"})+@($FontGateNetlist)}
    if($Test -eq 'tb_text_osd_pipeline'){$files+= "$board/sim/tb_image_contrast.v"}
    $simTops=@($Test)
    if($PhysicalOverlayRam){
        if($Test -notin @('tb_image_overlay_64','tb_overlay_protocol')){throw 'PhysicalOverlayRam requires an overlay test'}
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $hw=Join-Path $work 'image_overlay_hw.v'
        $source=(Get-Content "$board/rtl/ui/image_overlay_64.v" -Raw).Replace('DB_BEHAVIORAL_RAM','OVERLAY_FORCE_BEHAVIORAL_NEVER')
        [IO.File]::WriteAllText($hw,$source,[Text.UTF8Encoding]::new($false))
        $files=@($files | Where-Object {$_ -ne "$board/rtl/ui/image_overlay_64.v"})
        $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram32k.v",$hw)+$files
        $simTops+='glbl'
    }
    if($PhysicalSubtitleRam){
        if($Test -ne 'tb_sd_subtitle_view'){throw 'PhysicalSubtitleRam requires tb_sd_subtitle_view'}
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $hw=Join-Path $work 'subtitle_ram_hw.v'
        $source=(Get-Content "$board/rtl/ui/subtitle_ram.v" -Raw).Replace('`ifdef DB_BEHAVIORAL_RAM','`ifdef SUBTITLE_FORCE_BEHAVIORAL_NEVER')
        [IO.File]::WriteAllText($hw,$source,[Text.UTF8Encoding]::new($false))
        $files=@($files | Where-Object {$_ -ne "$board/rtl/ui/subtitle_ram.v"})
        $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram32k.v",$hw)+$files
        $simTops+='glbl'
    }
    if($Test -in @('tb_clock_overlay','tb_volume_text_pipeline','tb_volume_overlay','tb_text_osd_controller','tb_text_osd_events','tb_text_osd_cdc','tb_font_rom','tb_ui_text_overlay','tb_ui_frame_ppm','tb_text_osd_overlay','tb_text_osd_scroll','tb_text_osd_frame_ppm','tb_audio_osd_layout','tb_error_overlay','tb_image_contrast','tb_text_osd_pipeline')){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram32k.v")+$files
        $simTops+='glbl'
    }
    if($FontGateNetlist){
        $libs=@('al_map_lut.v','al_map_adder.v','al_map_basic.v','al_map_seq.v') | ForEach-Object {"$td/sim_release/common/$_"}
        $phy=@('eg_phy_lslice.v','eg_phy_mslice.v','eg_phy_pad.v','eg_phy_dff.v','eg_logic_io.v','eg_phy_config.v') | ForEach-Object {"$td/sim_release/eg4/$_"}
        $files=$libs+$phy+$files
    }
    if($Test -in @('tb_sdram_read_contract','tb_frame_read_dual')){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $files=@("$td/sim_release/eg4/eg_phy_sdram_2m_32.v")+$files
    }
    if($Test -eq 'tb_temac_gate'){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $libs=@('al_phy_glbl.v','al_map_lut.v','al_map_adder.v','al_map_basic.v') | ForEach-Object {"$td/sim_release/common/$_"}
        $files=@($libs)+@("$board/al_ip/TEMAC_CORE_gate.v")+$files
        $simTops+= 'glbl'
    }
    if($Test -eq 'tb_goertzel_height'){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram.v","$td/sim_release/eg4/eg_phy_bram32k.v","$td/sim_release/eg4/eg_logic_bram.v")+$files
        $simTops+='glbl'
    }
    $simInputHashes=[ordered]@{}
    foreach($simFile in ($files | Sort-Object -Unique)){
        $simInputHashes[[IO.Path]::GetFullPath($simFile)]=(Get-FileHash -LiteralPath $simFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    & (Join-Path $ms 'vlog.exe') -timescale '1ns/1ps' '+define+DB_BEHAVIORAL_RAM' "+incdir+$board/sim" "+incdir+$board/rtl" "+incdir+$board/rtl/ui" "+incdir+$board/rtl/link" "+incdir+$board/rtl/seam" "+incdir+$board/rtl/sdram" @files *> (Join-Path $work 'compile.txt')
    if($LASTEXITCODE -ne 0){Get-Content (Join-Path $work 'compile.txt');throw 'Compile failed'}
    $result=Join-Path $env:TEMP ($tag+'_vsim.txt')
    $plus=@("+AA_ATLAS=$board/sim/aa-font/atlas.hex","+AA_DIAG=$board/sim/aa-font/diagnostic.hex")
    if($Test -eq 'tb_calendar_clock'){
        & python "$board/sim/clock_reference.py" --out (Join-Path $work 'calendar.hex')
        if($LASTEXITCODE -ne 0){throw 'Gregorian oracle generation failed'}
        $plus+="+CALENDAR_VECTORS=$work/calendar.hex"
    }
    if($Test -eq 'tb_ui_frame_ppm'){$plus += @("+BG=$board/sim/bg_rgb.hex","+CASE=$UiCase")}
    if($Test -eq 'tb_clock_overlay' -and $ClockCase -ge 0){$plus+=@("-gFIRST_CASE=$ClockCase","-gLAST_CASE=$ClockCase")}
    & (Join-Path $ms 'vsim.exe') -c @plus -do 'run -all; quit -f' @simTops *> $result
    $out=Get-Content -LiteralPath $result -Raw
    if($out -notmatch '\*\*\* PASS \*\*\*'){Write-Host $out;throw "Simulation failed: $result"}
    foreach($simFile in $simInputHashes.Keys){
        if((Get-FileHash -LiteralPath $simFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $simInputHashes[$simFile]){throw "Simulation source changed: $simFile"}
    }
    Write-Host ($out | Select-String -Pattern '.*\*\*\* PASS.*' | ForEach-Object {$_.Matches.Value})
    New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
    $evidence=if($FontGateNetlist){$Test+'_gate'}elseif($PhysicalSubtitleRam){$Test+'_physical'}elseif($Test -eq 'tb_ui_frame_ppm'){$Test+'_case'+$UiCase}elseif($Test -eq 'tb_clock_overlay' -and $ClockCase -ge 0){$Test+'_case'+$ClockCase}else{$Test}
    if($PhysicalOverlayRam){$evidence+='_physical'}
    [IO.File]::WriteAllText((Join-Path $EvidenceDir "$evidence.txt"),[regex]::Replace($out,'(?m)[ \t]+(?=\r?$)',''))
    [IO.File]::WriteAllText((Join-Path $EvidenceDir "$evidence.inputs.json"),($simInputHashes | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if($Test -eq 'tb_emergency_overlay'){$frameDir=if($FrameDir){[IO.Path]::GetFullPath($FrameDir)}else{Join-Path $board '../build/emergency-time-v1/frames'};New-Item -ItemType Directory -Force -Path $frameDir | Out-Null;Get-ChildItem -LiteralPath $work -Filter 'emergency_*.ppm' | Copy-Item -Destination $frameDir -Force}
    if($Test -eq 'tb_ui_frame_ppm'){
        Get-ChildItem -LiteralPath $work -Filter 'ui_*_frame.ppm' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination "$board/../$($_.Name)" -Force
        }
    }
    if($Test -eq 'tb_clock_overlay'){
        $frameDir=if($FrameDir){[IO.Path]::GetFullPath($FrameDir)}else{Join-Path $board '../build/clock-v1/frames'}
        New-Item -ItemType Directory -Force $frameDir | Out-Null
        Get-ChildItem -LiteralPath $work -Filter 'clock_case_*.ppm' | Copy-Item -Destination $frameDir -Force
    }
    if($Test -eq 'tb_text_osd_frame_ppm'){
        $frameDir=if($FrameDir){[IO.Path]::GetFullPath($FrameDir)}else{Join-Path $board '../build/ui-text-osd-sim/frames'}
        New-Item -ItemType Directory -Force $frameDir | Out-Null
        Get-ChildItem -LiteralPath $work -Filter 'text_osd_*_frame.ppm' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $frameDir -Force
        }
    }
    if($Test -eq 'tb_audio_osd_layout'){
        $frameDir=if($FrameDir){[IO.Path]::GetFullPath($FrameDir)}else{Join-Path $board '../build/audio-spectrum-v1/frames'}
        New-Item -ItemType Directory -Force $frameDir | Out-Null
        Get-ChildItem -LiteralPath $work -Filter 'audio_spectrum_layout.ppm' | Copy-Item -Destination $frameDir -Force
    }
} finally {Pop-Location}
