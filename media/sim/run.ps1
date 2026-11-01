param([string]$Test='tb_link',[string]$EvidenceDir='',[switch]$SharedKeys,[switch]$ScaleFull,[int]$ScaleCase=-1,[switch]$SingleSector,[switch]$CancelGlitch,[switch]$ExternalPosition,[switch]$EmergencyMono,[switch]$PhysicalOverlayRam,[switch]$NoCompanions,[switch]$RealCard,[int]$CardTargetCluster=0,[ValidateSet('loop','gpio','quick','paused','format','missing','read_error','reset','disconnect','empty','reentry','render_reset','switch','paused_switch','restore_body_error','switch_many','pending_begin','cfg_race')][string]$EmergencyCase='loop')
$ErrorActionPreference='Stop'
$board=Split-Path -Parent $PSScriptRoot
if(-not $EvidenceDir){$EvidenceDir=Join-Path $board 'build/evidence'}
$EvidenceDir=[IO.Path]::GetFullPath($EvidenceDir)
$ms=if($env:MODELSIM_BIN){$env:MODELSIM_BIN}else{'D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'}
$tag=([Guid]::NewGuid().ToString('N'))
$work=Join-Path $env:TEMP ('dual_board_'+$tag)
New-Item -ItemType Directory -Path $work | Out-Null
Push-Location $work
try {
    & (Join-Path $ms 'vlib.exe') work | Out-Null
    $groups=@{
        tb_image_companion_switch=@()
        tb_media_metadata_timing=@('seam/db_stream_fifo.v','seam/seam_media.v')
        tb_sd_subtitle_fat=@('ui/subtitle_ram.v','ui/txt_prefix_parser.v','ui/sd_subtitle_controller.v','storage/storage_service.v','fat/fat32_ro.v','../../render/rtl/ui/sd_subtitle_view.v')
        tb_sd_subtitle_controller=@('ui/subtitle_ram.v','ui/txt_prefix_parser.v','ui/sd_subtitle_controller.v')
        tb_sd_overlay_controller=@('image/sd_overlay_controller.v')
        tb_overlay_watchdog=@('image/sd_overlay_controller.v')
        tb_txt_prefix_parser=@('ui/txt_prefix_parser.v')
        tb_emergency_media=@('emergency/emergency_media_controller.v')
        tb_volume_transport=@('seam/db_stream_fifo.v','seam/seam_media.v')
        tb_bmp_controller=@('image/fat_bmp_controller.v','clock/key_debounce.v')
        tb_bmp_header=@('image/bmp_header_parser.v','image/image_scale_geometry.v')
        tb_settings_rom=@('ui/settings_menu_text_rom.v')
        tb_keypad_images=@('image/fat_bmp_controller.v','clock/key_debounce.v')
        tb_keypad_router=@('clock/keypad_action_router.v')
        tb_audio_transport_gate=@('audio/audio_transport.v')
        tb_settings_menu=@('clock/key_debounce.v','clock/key_click_decode.v','clock/keypad_action_router.v','ui/file_browser.v','ui/settings_menu_text_rom.v')
        tb_file_browser_overlay=@('clock/key_debounce.v','clock/key_click_decode.v','ui/file_browser.v','ui/settings_menu_text_rom.v')
        tb_wav_header_parse=@('audio/wav_header_parse.v')
        tb_volume_controller=@('audio/volume_controller.v')
        tb_key_click=@('clock/key_click_decode.v','clock/keypad_action_router.v')
        tb_image_timeout=@('image/fat_bmp_controller.v','clock/key_debounce.v')
        tb_phy_status=@('link/db_ethernet.v')
        tb_rx_clk_buf=@('link/vendor/rgmii_interface.v')
        tb_sdio_phy=@('sd/sdio_phy.v')
        tb_lba_bounds=@('storage/lba_stream.v')
        tb_link=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_link_sequence=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_temac_gate=@('link/db_ethernet.v','link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v','link/db_link.v')
        tb_rx_full=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v')
        tb_rx_header_commit=@('link/db_packet_ram.v','link/db_async_fifo.v','link/db_mac_rx.v')
        tb_stream_fifo=@('seam/db_stream_fifo.v')
        tb_media_source=@('seam/db_stream_fifo.v','seam/seam_media.v')
        tb_seam_overlay_tx=@('seam/db_stream_fifo.v','seam/seam_media.v')
        tb_media_sd_boot=@('media_core.v','clock/key_debounce.v','clock/key_click_decode.v','clock/keypad_action_router.v','audio/audio_transport.v','audio/fat_wav_controller.v','audio/wav_header_parse.v','audio/wav_pcm_unpack.v','audio/wav_playlist.v','fat/fat32_ro.v','fat/fat_chain_map.v','framebuffer/rgb888_word_packer.v','glue/glue_storage.v','image/fat_bmp_controller.v','image/sd_overlay_controller.v','storage/lba_stream.v','storage/storage_service.v','ui/file_browser.v','ui/settings_menu_text_rom.v','seam/db_stream_fifo.v','seam/seam_media.v')
        tb_fat32_ro=@('fat/fat32_ro.v')
        tb_media_resource_primitives=@('fat/fat32_ro.v')
        tb_fat32_directory=@('fat/fat32_ro.v')
        tb_fat32_map=@('fat/fat32_ro.v')
        tb_fat32_timeout=@('fat/fat32_ro.v')
        tb_fat_wav_controller=@('audio/fat_wav_controller.v','audio/wav_header_parse.v','audio/wav_pcm_unpack.v','storage/lba_stream.v')
        tb_fat_wav_actual=@('audio/fat_wav_controller.v','audio/wav_header_parse.v','audio/wav_pcm_unpack.v','storage/lba_stream.v')
    }
    if($Test -in @('tb_bmp_scale','tb_bmp_overflow')){$groups[$Test]=@()}
    if($Test -eq 'tb_emergency_integration'){$groups[$Test]=@()}
    if($Test -eq 'tb_media_overlay_e2e'){$groups[$Test]=@()}
    if(-not $groups.ContainsKey($Test)){throw "Unknown test $Test"}
    $imageFiles=@('image/bmp_header_parser.v','image/bmp_pixel_unpack.v','image/image_scale_geometry.v','image/image_row_store.v','image/image_scale_nearest.v','image/bmp_image_pipeline.v','framebuffer/rgb888_word_packer.v')
    foreach($name in @('tb_keypad_images','tb_image_timeout','tb_media_sd_boot','tb_bmp_controller')){$groups[$name]=@($groups[$name]+$imageFiles | Select-Object -Unique)}
    $groups['tb_bmp_scale']=$imageFiles
    $groups['tb_bmp_overflow']=$imageFiles
    foreach($name in @('tb_settings_menu','tb_media_sd_boot')){$groups[$name]+='audio/volume_controller.v'}
    $groups['tb_media_sd_boot']+=@('emergency/emergency_media_controller.v','ui/subtitle_ram.v','ui/txt_prefix_parser.v','ui/sd_subtitle_controller.v')
    $groups['tb_image_companion_switch']=$groups['tb_media_sd_boot']
    $groups['tb_emergency_integration']=$groups['tb_media_sd_boot']+@('../../render/rtl/seam/seam_render.v','../../render/rtl/emergency/emergency_controller.v','../../render/rtl/emergency/emergency_inputs.v','../../render/rtl/seam/db_audio_sink.v','../../render/rtl/audio/audio_ring_bram.v','../../render/rtl/audio/wav_play_glue.v','../../render/rtl/audio/audio_wav_pcm.v')
    $groups['tb_media_overlay_e2e']=$groups['tb_media_sd_boot']+@('../../render/rtl/seam/seam_render.v','../../render/rtl/ui/image_overlay_64.v')
    if($Test -eq 'tb_sd_subtitle_controller'){$groups[$Test]+=@('../../render/rtl/ui/sd_subtitle_view.v')}
    $files=@($groups[$Test] | ForEach-Object {"$board/rtl/$_"})+@("$board/sim/$Test.v")
    if($Test -eq 'tb_fat_wav_actual'){$files=@("$board/sim/tb_fat_wav_controller.v")+$files}
    if($Test -eq 'tb_emergency_integration'){$files=@("$board/sim/sd_emergency_stub.v")+$files}
    if($Test -in @('tb_media_sd_boot','tb_media_overlay_e2e','tb_image_companion_switch')){$files=@("$board/sim/sd_boot_stub.v")+$files}
    $simParameters=@();$evidenceName=$Test
    if($NoCompanions){
        if($Test -ne 'tb_image_companion_switch'){throw 'NoCompanions requires tb_image_companion_switch'}
        $simParameters=@('-gCOMPANIONS=0');$evidenceName+='_no_companions'
    }
    if($RealCard){
        if($Test -ne 'tb_image_companion_switch'){throw 'RealCard requires tb_image_companion_switch'}
        $capture=Join-Path $board 'build/evidence/sd-card-image-probe'
        $captureInfo=Get-Content (Join-Path $capture 'manifest.json') -Raw | ConvertFrom-Json
        $simParameters=@('-gREAL_CARD=1',"-gCARD_TARGET_CLUSTER=$CardTargetCluster","+CARD_COUNT=$($captureInfo.sector_count)","+CARD_LBAS=$capture/lbas.hex","+CARD_BYTES=$capture/bytes.hex")
        $evidenceName+='_real_card'
        if($CardTargetCluster -ne 0){$evidenceName+="_cluster$CardTargetCluster"}
    }
    if($EmergencyMono){$simParameters=@('+EM_MONO');$evidenceName+='_mono'}
    if($EmergencyCase -ne 'loop'){$simParameters+=('+EM_'+$EmergencyCase.ToUpperInvariant());$evidenceName+='_'+$EmergencyCase}
    if($SharedKeys){if($Test -ne 'tb_settings_menu'){throw 'SharedKeys requires tb_settings_menu'};$simParameters=@('-gSHARED_OK=1');$evidenceName=$Test+'_shared'}
    if($Test -eq 'tb_bmp_scale'){
        $reference=Join-Path $board 'sim/bmp_scale_reference.py'
        $refArgs=@('--out',$work);if($ScaleFull){$refArgs+='--full'}
        & python $reference @refArgs
        if($LASTEXITCODE -ne 0){throw 'Scale fixture generation failed'}
        $simParameters=@("-gCASE=$ScaleCase")
        if($ScaleFull){$simParameters+=@('-gDST_W=1280','-gDST_H=720')}
        $evidenceName+="_case$ScaleCase";if($ScaleFull){$evidenceName+='_720p'}
    }
    if($SingleSector){
        if($Test -ne 'tb_fat32_ro'){throw 'SingleSector requires tb_fat32_ro'}
        $simParameters=@('-gFILE_MAX_BURST=1');$evidenceName+='_single_sector'
    }
    if($Test -eq 'tb_media_sd_boot' -and $ScaleFull){$simParameters=@('-gCOMPLETE=1');$evidenceName+='_720p'}
    if($CancelGlitch){if($Test -ne 'tb_bmp_controller'){throw 'CancelGlitch requires tb_bmp_controller'};$simParameters=@('-gCANCEL_GLITCH=1');$evidenceName+='_cancel_glitch'}
    if($ExternalPosition){if($Test -ne 'tb_fat_wav_controller'){throw 'ExternalPosition requires tb_fat_wav_controller'};$simParameters=@('-gEXTERNAL_POSITION=1');$evidenceName+='_external_position'}
    $simTops=@($Test)
    if($PhysicalOverlayRam){
        if($Test -ne 'tb_media_overlay_e2e'){throw 'PhysicalOverlayRam requires tb_media_overlay_e2e'}
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $hw=Join-Path $work 'image_overlay_hw.v'
        $source=(Get-Content "$board/../render/rtl/ui/image_overlay_64.v" -Raw).Replace('DB_BEHAVIORAL_RAM','OVERLAY_FORCE_BEHAVIORAL_NEVER')
        [IO.File]::WriteAllText($hw,$source,[Text.UTF8Encoding]::new($false))
        $files=@($files | Where-Object {$_ -ne "$board/rtl/../../render/rtl/ui/image_overlay_64.v"})
        $files=@("$td/sim_release/common/al_phy_glbl.v","$td/sim_release/eg4/eg_phy_bram32k.v",$hw)+$files
        $simTops+='glbl';$evidenceName+='_physical'
    }
    if($Test -eq 'tb_settings_rom'){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $hw=Join-Path $work 'settings_rom_hw.v'
        $source=Get-Content "$board/rtl/ui/settings_menu_text_rom.v" -Raw
        $source=$source.Replace('settings_menu_row_decode','settings_menu_row_decode_hw').Replace('module settings_menu_text_rom(', 'module settings_menu_text_rom_hw(').Replace('`ifdef DB_BEHAVIORAL_RAM','`ifdef ROM_FORCE_BEHAVIORAL_NEVER')
        [IO.File]::WriteAllText($hw,'`undef DB_BEHAVIORAL_RAM'+"`n"+$source,[Text.UTF8Encoding]::new($false))
        $files=@("$board/rtl/ui/settings_menu_text_rom.v",$hw,"$td/sim_release/eg4/eg_phy_bram.v","$td/sim_release/eg4/eg_phy_bram32k.v","$td/sim_release/common/al_phy_glbl.v","$board/sim/tb_settings_rom.v")
        $simTops+='glbl'
    }

    if($Test -eq 'tb_temac_gate'){
        $td=if($env:TD_ROOT){$env:TD_ROOT}else{'D:/AnLu_FPGA_environment'}
        $libs=@('al_phy_glbl.v','al_map_lut.v','al_map_adder.v','al_map_basic.v') | ForEach-Object {"$td/sim_release/common/$_"}
        $files=@($libs)+@("$board/al_ip/TEMAC_CORE_gate.v")+$files
        $simTops+= 'glbl'
    }
    $simInputHashes=[ordered]@{}
    $fixtureHashFiles=@()
    if($RealCard){$fixtureHashFiles=@("$capture/manifest.json","$capture/lbas.hex","$capture/bytes.hex")}

    foreach($simFile in (@($files)+$fixtureHashFiles | Sort-Object -Unique)){
        $simInputHashes[[IO.Path]::GetFullPath($simFile)]=(Get-FileHash -LiteralPath $simFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    & (Join-Path $ms 'vlog.exe') '+define+DB_BEHAVIORAL_RAM' "+incdir+$board/rtl" "+incdir+$board/rtl/pkg" "+incdir+$board/rtl/link" "+incdir+$board/rtl/seam" @files *> (Join-Path $work 'compile.txt')
    if($LASTEXITCODE -ne 0){Get-Content (Join-Path $work 'compile.txt');throw 'Compile failed'}
    $result=Join-Path $env:TEMP ($tag+'_vsim.txt')
    & (Join-Path $ms 'vsim.exe') -c @simParameters -do 'run -all; quit -f' @simTops *> $result
    $out=Get-Content -LiteralPath $result -Raw
    if($out -notmatch '\*\*\* PASS \*\*\*'){Write-Host $out;throw "Simulation failed: $result"}
    foreach($simFile in $simInputHashes.Keys){
        if((Get-FileHash -LiteralPath $simFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $simInputHashes[$simFile]){throw "Simulation source changed: $simFile"}
    }
    Write-Host ($out | Select-String -Pattern '.*\*\*\* PASS.*' | ForEach-Object {$_.Matches.Value})
    New-Item -ItemType Directory -Force "$EvidenceDir" | Out-Null
    [IO.File]::WriteAllText("$EvidenceDir/$evidenceName.txt",[regex]::Replace($out,'(?m)[ \t]+(?=\r?$)',''))
    [IO.File]::WriteAllText("$EvidenceDir/$evidenceName.inputs.json",($simInputHashes | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if($Test -eq 'tb_media_overlay_e2e'){
        foreach($capture in (Get-ChildItem -LiteralPath $work -Filter 'overlay_output*.ppm')){
            $captureSuffix=$capture.Name.Substring('overlay_output'.Length)
            Copy-Item -LiteralPath $capture.FullName -Destination "$EvidenceDir/${evidenceName}${captureSuffix}" -Force
        }
    }
} finally {Pop-Location}
