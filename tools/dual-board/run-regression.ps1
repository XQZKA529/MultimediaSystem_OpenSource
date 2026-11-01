param([switch]$SkipSystem,[switch]$ResumeRenderUi)
$ErrorActionPreference='Stop'
$dbRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $dbRoot
try{
 if(-not $ResumeRenderUi){
 & (Join-Path $PSScriptRoot 'run-emergency.ps1') -SkipRegression
 $dbTests=@{
  media=@('tb_txt_prefix_parser','tb_sd_subtitle_controller','tb_sd_subtitle_fat','tb_volume_transport','tb_volume_controller','tb_wav_header_parse','tb_bmp_header','tb_bmp_controller','tb_bmp_overflow','tb_settings_rom','tb_keypad_images','tb_keypad_router','tb_audio_transport_gate','tb_key_click','tb_settings_menu','tb_phy_status','tb_link','tb_temac_gate','tb_rx_full','tb_rx_header_commit','tb_media_source','tb_media_sd_boot','tb_image_timeout','tb_fat32_ro','tb_fat32_directory','tb_fat32_map','tb_fat32_timeout','tb_lba_bounds','tb_fat_wav_controller','tb_fat_wav_actual')
  render=@('tb_sd_subtitle_view','tb_volume_text_pipeline','tb_volume_protocol','tb_audio_volume_gain','tb_volume_view_cdc','tb_volume_overlay','tb_font_rom','tb_text_osd_controller','tb_text_osd_events','tb_text_osd_cdc','tb_text_osd_overlay','tb_text_osd_frame_ppm','tb_text_osd_pipeline','tb_tm1650_keypad','tb_keypad_events','tb_contrast_adjust','tb_saturation_adjust','tb_goertzel_height','tb_image_contrast','tb_brightness_scale','tb_ddcci_brightness','tb_phy_status','tb_error_overlay','tb_link','tb_temac_gate','tb_image_commit','tb_ui_snapshot','tb_audio_sink','tb_frame_vflip','tb_frame_abort','tb_sdram_read_contract','tb_frame_read_dual','tb_pixel_mixer','tb_mix_alpha','tb_mix_transition','tb_ui_values','tb_ui_text_overlay')
 }
 foreach($dbBoard in @('media','render')){
  if($dbBoard -eq 'render'){
   foreach($clockTest in @('tb_calendar_clock','tb_clock_view_cdc','tb_clock_events','tb_clock_overlay')){
    & (Join-Path $dbRoot 'render/sim/run.ps1') -Test $clockTest -EvidenceDir (Join-Path $dbRoot 'build/clock-v1/evidence')
   }
  }
  foreach($dbTest in $dbTests[$dbBoard]){& (Join-Path $dbRoot "$dbBoard/sim/run.ps1") -Test $dbTest}
  if($dbBoard -eq 'media'){& (Join-Path $dbRoot 'media/sim/run.ps1') -Test tb_bmp_controller -CancelGlitch;& (Join-Path $dbRoot "media/sim/run.ps1") -Test tb_settings_menu -SharedKeys;& (Join-Path $dbRoot "media/sim/run.ps1") -Test tb_fat32_ro -SingleSector}
  if($dbBoard -eq 'media'){
   & (Join-Path $dbRoot 'media/sim/run.ps1') -Test tb_stream_fifo
   & (Join-Path $dbRoot 'media/sim/run.ps1') -Test tb_fat_wav_controller -ExternalPosition
  }
  if($dbBoard -eq 'render'){& (Join-Path $dbRoot 'render/sim/run.ps1') -Test tb_sd_subtitle_view -PhysicalSubtitleRam}
  & (Join-Path $dbRoot "$dbBoard/diag/sim.ps1")
 }
 }else{
  & (Join-Path $dbRoot 'render/sim/run.ps1') -Test tb_ui_text_overlay
  & (Join-Path $dbRoot 'render/sim/run.ps1') -Test tb_sd_subtitle_view -PhysicalSubtitleRam
  & (Join-Path $dbRoot 'render/diag/sim.ps1')
 }
 if(-not $SkipSystem){
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_sd_subtitle_system
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_text_osd_menu
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_text_osd_menu -VolumeRetry
  & (Join-Path $dbRoot 'media/sim/run.ps1') -Test tb_media_sd_boot -ScaleFull
  & (Join-Path $dbRoot 'media/sim/run.ps1') -Test tb_bmp_scale -ScaleFull
  & (Join-Path $PSScriptRoot 'run-system.ps1') -ScaleBmp
  & (Join-Path $PSScriptRoot 'run-system.ps1') -ScaleFull
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -ScaleBmp
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -ScaleFull
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -ScaleBmp -Scenario 2
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -ScaleBmp -Mono
  & (Join-Path $PSScriptRoot 'run-system.ps1')
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -Scenario 2
  & (Join-Path $PSScriptRoot 'run-system.ps1') -Test tb_audio_system -Mono
 }
 & python (Join-Path $PSScriptRoot 'audit.py')
 if($LASTEXITCODE -ne 0){throw 'Package audit failed'}
 if($ResumeRenderUi){Write-Host 'PASS resumed dual-board regression/package audit'}
 else{Write-Host 'PASS dual-board regression/package audit'}
}finally{Pop-Location}
