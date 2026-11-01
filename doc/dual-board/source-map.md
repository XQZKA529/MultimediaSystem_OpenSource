# 双板源码与功能索引

本页按两板实际 `build/sources.txt`、顶层实例、include 与约束组织源码。系统功能和操作见[主 README](../../README.md)，板内解释见 [media](../../media/README.md)、[render](../../render/README.md)。源目录中保留的兼容模块、未启动通路和厂商核不按文件名自动计作系统功能。

## 功能到实现

| 功能 / 契约 | media 实现 | render 实现 |
|---|---|---|
| 板级时钟与复位 | top_media、board_sys_pll、board_reset、reset_sync | top_render、board_sys_pll、video_pll、board_reset、reset_sync |
| SDIO与两读者仲裁 | sd_card_sdio、sdio_core、sdio_cmd、sdio_phy、sd_crc | — |
| FAT32挂载、LFN/SFN、簇链保护 | storage_service、fat32_ro、fat_chain_map、lba_stream | — |
| BMP头、解包、contain、行缓存 | fat_bmp_controller、bmp_header_parser、bmp_pixel_unpack、image_scale_geometry、image_scale_nearest、image_row_store、bmp_image_pipeline | 收到的已是固定720p像素 |
| RGB888紧凑打包与翻转 | rgb888_word_packer | rgb888_word_reader、frame_fifo_write |
| 双帧读写与安全交接 | 等待READY/PRESENTED | frame_read_write、frame_fifo_read_dual、frame_fifo_write、sdram_app_arb、sdram |
| 四种转场选项 | file_browser、seam_media | seam_render、mix_transition_ctrl、mix_alpha_ctrl、pixel_mixer、render_core |
| 目录与十项设置 | file_browser、settings_menu_text_rom、keypad_action_router | ui_text_overlay、本地编辑器、共享字模/调色ROM |
| WAV与下一首 | fat_wav_controller、wav_header_parse、wav_pcm_unpack、wav_playlist、audio_transport | db_audio_sink、wav_play_glue、audio_ring_bram、audio_wav_pcm |
| 图片配音、轮播间隔、背景恢复 | media_core、sd_subtitle_controller、fat_bmp_controller | image ID、PCM_POSITION反馈 |
| 音量与提示 | volume_controller、VOLUME_SET | volume_view_cdc、audio_volume_gain、volume_hint_controller、volume_overlay |
| 播放进度/频谱 | PCM与总帧数 | db_audio_model、audio_goertzel_osd、audio_osd_overlay、osd_paint_* |
| 本地文字编辑 | 菜单入口 | text_osd_controller、text_osd_ram、text_osd_event_router、text_osd_view_cdc、text_osd_overlay |
| SD手动/自动字幕 | txt_prefix_parser、sd_subtitle_controller、subtitle_ram | sd_subtitle_view、subtitle_ram、text_osd_overlay |
| 固定台标 | sd_overlay_controller、OVL对象事务 | seam_render、image_overlay_64 |
| 亮度/对比度/饱和度 | 菜单值与快照 | ddcci_brightness、ddc_i2c_master、brightness_scale、contrast_adjust、saturation_adjust |
| TM1650、板载单/双击/长按 | key_debounce、key_click_decode、audio_transport、keypad_action_router | tm1650_keypad、keypad_event_encoder、text_osd_event_router |
| 日历、编辑与常驻时钟 | CLOCK页面生命周期 | calendar_clock、clock_view_cdc、clock_overlay |
| 三路应急、顺序和触发时间 | emergency_media_controller、历史/音轨恢复 | emergency_inputs、emergency_controller、emergency_view_cdc、emergency_overlay |
| 业务链路、CRC、信用、重连 | db_ethernet、db_link、db_mac_rx、db_packet_ram、db_async_fifo、seam_media | 各自本板链路副本、seam_render、db_audio_sink |
| HDMI视频与数据岛音频 | — | hdmi_audio_driver、video_to_axis、audio_arc_calculate、HDMI加密核、hdmi_phy、lane_lvds_10_1 |
| 诊断横幅与状态 | SD/FAT/图片状态、STATUS刷新 | error_overlay、render_core的本地扫描故障与状态选择 |
| 独立PRBS31 | diag/top_linktest_media、db_prbs_mac | diag/top_linktest_render、db_prbs_mac |

## 参数与外部契约出处

- 两板 `rtl/pkg/board_link.vh`：协议1.14、固定MAC/EtherType、通道和opcode。
- 两板 `rtl/pkg/video_bmp_params.vh`：几何/字布局；media总线50MHz、render总线100MHz。render的播放卡片/频谱坐标以render副本为准，media副本中保留的旧OSD坐标不控制输出。
- `render/rtl/pkg/text_osd_model.vh`：256字符、本地文字模型位域；两板 `fat_dir_bus.vh`、`fat_err_codes.vh`、`osd_model_bus.vh`为目录/错误/OSD契约。
- `media/rtl/top_media.v`覆盖链路重传参数，且media重传计数半速；render保持自己的默认计数，不能只读db_link参数默认值推算两板行为。
- `media/rtl/media_core.v`决定SD时钟参数、音频单扇区、字幕与配音归属；`render/rtl/render_core.v`决定图层先后、显隐、音量前频谱及SDRAM通路。
- 两板 `clock/board_sys_pll.v`、render `video_pll.v`的原语参数决定实际频率；不能把未例化的sys_pll或历史注释当作当前时钟配置。
- `constr/*.adc`决定物理引脚/virtualIO；`constr/*.sdc`定义工具STA边界。渲染VGA/调试口为virtualIO，MDC/MDIO并无主动PHY配置。
- 各板build/run、MyFlow、check-reports、input-fingerprint共同决定构建和签核。仿真宏DB_BEHAVIORAL_RAM用于模型替代，发布路径使用厂商原语/IP。

## RTL文件清单

下面“清单内”仅表示被主功能工程sources.txt列入，不代表每个module都会被顶层例化；未使用模块会被综合裁掉。ROM初始化/调色表与资源保持器属于相应图层实现，不是新的用户功能。HDMI/TEMAC及SDRAM控制相关厂商加密部分只能核对公开封装/端口、参数和调用契约，无法阅读加密内部实现。

### media

主清单包含54项RTL/IP/约束，其中51个Verilog文件；rtl目录共53个Verilog文件。

| 文件 | 主模块 / 附属模块 | 清单 |
|---|---|---|
| [rtl/audio/audio_transport.v](../../media/rtl/audio/audio_transport.v) | `audio_transport` | 清单内 |
| [rtl/audio/fat_wav_controller.v](../../media/rtl/audio/fat_wav_controller.v) | `fat_wav_controller` | 清单内 |
| [rtl/audio/volume_controller.v](../../media/rtl/audio/volume_controller.v) | `volume_controller` | 清单内 |
| [rtl/audio/wav_header_parse.v](../../media/rtl/audio/wav_header_parse.v) | `wav_header_parse` | 清单内 |
| [rtl/audio/wav_pcm_unpack.v](../../media/rtl/audio/wav_pcm_unpack.v) | `wav_pcm_unpack` | 清单内 |
| [rtl/audio/wav_playlist.v](../../media/rtl/audio/wav_playlist.v) | `wav_playlist` | 清单内 |
| [rtl/clock/board_reset.v](../../media/rtl/clock/board_reset.v) | `board_reset` | 清单内 |
| [rtl/clock/board_sys_pll.v](../../media/rtl/clock/board_sys_pll.v) | `board_sys_pll` | 清单内 |
| [rtl/clock/key_click_decode.v](../../media/rtl/clock/key_click_decode.v) | `key_click_decode` | 清单内 |
| [rtl/clock/key_debounce.v](../../media/rtl/clock/key_debounce.v) | `key_debounce` | 清单内 |
| [rtl/clock/keypad_action_router.v](../../media/rtl/clock/keypad_action_router.v) | `keypad_action_router` | 清单内 |
| [rtl/clock/reset_sync.v](../../media/rtl/clock/reset_sync.v) | `reset_sync` | 清单内 |
| [rtl/clock/sys_pll.v](../../media/rtl/clock/sys_pll.v) | `sys_pll` | 未列入 |
| [rtl/emergency/emergency_media_controller.v](../../media/rtl/emergency/emergency_media_controller.v) | `emergency_media_controller` | 清单内 |
| [rtl/fat/fat32_ro.v](../../media/rtl/fat/fat32_ro.v) | `fat32_ro`, `resource_fat_ff_hold`, `resource_fat_dsp_hold`（另3个附属模块） | 清单内 |
| [rtl/fat/fat_chain_map.v](../../media/rtl/fat/fat_chain_map.v) | `fat_chain_map` | 清单内 |
| [rtl/framebuffer/rgb888_word_packer.v](../../media/rtl/framebuffer/rgb888_word_packer.v) | `rgb888_word_packer` | 清单内 |
| [rtl/glue/glue_storage.v](../../media/rtl/glue/glue_storage.v) | `glue_storage` | 清单内 |
| [rtl/glue/glue_video_ctrl.v](../../media/rtl/glue/glue_video_ctrl.v) | `glue_video_ctrl` | 未列入 |
| [rtl/image/bmp_header_parser.v](../../media/rtl/image/bmp_header_parser.v) | `bmp_header_parser` | 清单内 |
| [rtl/image/bmp_image_pipeline.v](../../media/rtl/image/bmp_image_pipeline.v) | `bmp_image_pipeline` | 清单内 |
| [rtl/image/bmp_pixel_unpack.v](../../media/rtl/image/bmp_pixel_unpack.v) | `bmp_pixel_unpack` | 清单内 |
| [rtl/image/fat_bmp_controller.v](../../media/rtl/image/fat_bmp_controller.v) | `fat_bmp_controller` | 清单内 |
| [rtl/image/image_row_store.v](../../media/rtl/image/image_row_store.v) | `image_row_store` | 清单内 |
| [rtl/image/image_scale_geometry.v](../../media/rtl/image/image_scale_geometry.v) | `image_scale_geometry` | 清单内 |
| [rtl/image/image_scale_nearest.v](../../media/rtl/image/image_scale_nearest.v) | `image_scale_nearest` | 清单内 |
| [rtl/image/sd_overlay_controller.v](../../media/rtl/image/sd_overlay_controller.v) | `sd_overlay_controller` | 清单内 |
| [rtl/link/db_async_fifo.v](../../media/rtl/link/db_async_fifo.v) | `db_async_fifo` | 清单内 |
| [rtl/link/db_ethernet.v](../../media/rtl/link/db_ethernet.v) | `db_ethernet` | 清单内 |
| [rtl/link/db_link.v](../../media/rtl/link/db_link.v) | `db_link`, `db_sequence_hold` | 清单内 |
| [rtl/link/db_mac_rx.v](../../media/rtl/link/db_mac_rx.v) | `db_mac_rx`, `db_management_word_fifo` | 清单内 |
| [rtl/link/db_packet_ram.v](../../media/rtl/link/db_packet_ram.v) | `db_packet_ram` | 清单内 |
| [rtl/link/vendor/IDDR.v](../../media/rtl/link/vendor/IDDR.v) | `IDDR` | 清单内 |
| [rtl/link/vendor/ODDR.v](../../media/rtl/link/vendor/ODDR.v) | `ODDR` | 清单内 |
| [rtl/link/vendor/rgmii_interface.v](../../media/rtl/link/vendor/rgmii_interface.v) | `rgmii_interface`, `db_rx_clk_buf` | 清单内 |
| [rtl/link/vendor/temac_block.v](../../media/rtl/link/vendor/temac_block.v) | `temac_block` | 清单内 |
| [rtl/link/vendor/tx_clk_en_gen.v](../../media/rtl/link/vendor/tx_clk_en_gen.v) | `tx_clk_en_gen` | 清单内 |
| [rtl/media_core.v](../../media/rtl/media_core.v) | `media_core` | 清单内 |
| [rtl/sd/sd_card_sdio.v](../../media/rtl/sd/sd_card_sdio.v) | `sd_card_sdio` | 清单内 |
| [rtl/sd/sd_crc.v](../../media/rtl/sd/sd_crc.v) | `sd_crc7`, `sd_crc16` | 清单内 |
| [rtl/sd/sdio_cmd.v](../../media/rtl/sd/sdio_cmd.v) | `sdio_cmd` | 清单内 |
| [rtl/sd/sdio_core.v](../../media/rtl/sd/sdio_core.v) | `sdio_core` | 清单内 |
| [rtl/sd/sdio_phy.v](../../media/rtl/sd/sdio_phy.v) | `sdio_phy` | 清单内 |
| [rtl/seam/db_stream_fifo.v](../../media/rtl/seam/db_stream_fifo.v) | `db_stream_fifo` | 清单内 |
| [rtl/seam/seam_media.v](../../media/rtl/seam/seam_media.v) | `seam_media` | 清单内 |
| [rtl/storage/lba_stream.v](../../media/rtl/storage/lba_stream.v) | `lba_stream` | 清单内 |
| [rtl/storage/storage_service.v](../../media/rtl/storage/storage_service.v) | `storage_service` | 清单内 |
| [rtl/top_media.v](../../media/rtl/top_media.v) | `top_media` | 清单内 |
| [rtl/ui/file_browser.v](../../media/rtl/ui/file_browser.v) | `file_browser` | 清单内 |
| [rtl/ui/sd_subtitle_controller.v](../../media/rtl/ui/sd_subtitle_controller.v) | `sd_subtitle_controller` | 清单内 |
| [rtl/ui/settings_menu_text_rom.v](../../media/rtl/ui/settings_menu_text_rom.v) | `settings_menu_text_rom`, `settings_menu_row_decode` | 清单内 |
| [rtl/ui/subtitle_ram.v](../../media/rtl/ui/subtitle_ram.v) | `subtitle_ram` | 清单内 |
| [rtl/ui/txt_prefix_parser.v](../../media/rtl/ui/txt_prefix_parser.v) | `txt_prefix_parser` | 清单内 |

头文件：[rtl/link/db_crc.vh](../../media/rtl/link/db_crc.vh)、[rtl/pkg/board_link.vh](../../media/rtl/pkg/board_link.vh)、[rtl/pkg/fat_dir_bus.vh](../../media/rtl/pkg/fat_dir_bus.vh)、[rtl/pkg/fat_err_codes.vh](../../media/rtl/pkg/fat_err_codes.vh)、[rtl/pkg/image_scale_modes.vh](../../media/rtl/pkg/image_scale_modes.vh)、[rtl/pkg/osd_model_bus.vh](../../media/rtl/pkg/osd_model_bus.vh)、[rtl/pkg/video_bmp_params.vh](../../media/rtl/pkg/video_bmp_params.vh)。

### render

主清单包含84项RTL/IP/约束，其中81个Verilog文件；rtl目录共89个Verilog文件。

| 文件 | 主模块 / 附属模块 | 清单 |
|---|---|---|
| [rtl/audio/audio_ring_bram.v](../../render/rtl/audio/audio_ring_bram.v) | `audio_ring_bram` | 清单内 |
| [rtl/audio/audio_volume_gain.v](../../render/rtl/audio/audio_volume_gain.v) | `audio_volume_gain` | 清单内 |
| [rtl/audio/audio_wav_pcm.v](../../render/rtl/audio/audio_wav_pcm.v) | `audio_wav_pcm` | 清单内 |
| [rtl/audio/volume_view_cdc.v](../../render/rtl/audio/volume_view_cdc.v) | `volume_view_cdc` | 清单内 |
| [rtl/audio/wav_play_glue.v](../../render/rtl/audio/wav_play_glue.v) | `wav_play_glue` | 清单内 |
| [rtl/clock/board_reset.v](../../render/rtl/clock/board_reset.v) | `board_reset` | 清单内 |
| [rtl/clock/board_sys_pll.v](../../render/rtl/clock/board_sys_pll.v) | `board_sys_pll` | 清单内 |
| [rtl/clock/reset_sync.v](../../render/rtl/clock/reset_sync.v) | `reset_sync` | 清单内 |
| [rtl/clock/sys_pll.v](../../render/rtl/clock/sys_pll.v) | `sys_pll` | 未列入 |
| [rtl/clock/video_pll.v](../../render/rtl/clock/video_pll.v) | `video_pll` | 清单内 |
| [rtl/driver/audio_arc_calculate.v](../../render/rtl/driver/audio_arc_calculate.v) | `audio_arc_calculate` | 清单内 |
| [rtl/driver/ddc_i2c_master.v](../../render/rtl/driver/ddc_i2c_master.v) | `ddc_i2c_master` | 清单内 |
| [rtl/driver/ddcci_brightness.v](../../render/rtl/driver/ddcci_brightness.v) | `ddcci_brightness` | 清单内 |
| [rtl/driver/hdmi_1_4b_transmitter_core_wrapper.enc.v](../../render/rtl/driver/hdmi_1_4b_transmitter_core_wrapper.enc.v) | `hdmi_1_4b_transmitter_core_wrapper` | 清单内 |
| [rtl/driver/hdmi_audio_driver.v](../../render/rtl/driver/hdmi_audio_driver.v) | `hdmi_audio_driver` | 清单内 |
| [rtl/driver/hdmi_phy.v](../../render/rtl/driver/hdmi_phy.v) | `hdmi_phy` | 清单内 |
| [rtl/driver/keypad_event_encoder.v](../../render/rtl/driver/keypad_event_encoder.v) | `keypad_event_encoder` | 清单内 |
| [rtl/driver/lane_lvds_10_1.v](../../render/rtl/driver/lane_lvds_10_1.v) | `lane_lvds_10_1` | 清单内 |
| [rtl/driver/startup_pulse.v](../../render/rtl/driver/startup_pulse.v) | `startup_pulse` | 未列入 |
| [rtl/driver/tm1650_keypad.v](../../render/rtl/driver/tm1650_keypad.v) | `tm1650_keypad` | 清单内 |
| [rtl/driver/video_to_axis.v](../../render/rtl/driver/video_to_axis.v) | `video_to_axis` | 清单内 |
| [rtl/emergency/emergency_controller.v](../../render/rtl/emergency/emergency_controller.v) | `emergency_controller` | 清单内 |
| [rtl/emergency/emergency_inputs.v](../../render/rtl/emergency/emergency_inputs.v) | `emergency_inputs` | 清单内 |
| [rtl/emergency/emergency_overlay.v](../../render/rtl/emergency/emergency_overlay.v) | `emergency_overlay`, `resource_emergency_pair_rom`, `resource_emergency_dsp_pipe2` | 清单内 |
| [rtl/emergency/emergency_view_cdc.v](../../render/rtl/emergency/emergency_view_cdc.v) | `emergency_view_cdc` | 清单内 |
| [rtl/fft/audio_fft_osd.v](../../render/rtl/fft/audio_fft_osd.v) | `audio_goertzel_osd`, `audio_fft_osd`, `resource_goertzel_history_ram` | 清单内 |
| [rtl/framebuffer/afifo_16_32_256.v](../../render/rtl/framebuffer/afifo_16_32_256.v) | `wfifo_32_32_512`, `fifo_cross_domain_addr_process_al_wfifo_32_32_512`, `ram_infer_wfifo_32_32_512` | 清单内 |
| [rtl/framebuffer/afifo_32_16_256.v](../../render/rtl/framebuffer/afifo_32_16_256.v) | `rfifo_32_32_512`, `fifo_cross_domain_addr_process_al_rfifo_32_32_512`, `ram_infer_rfifo_32_32_512` | 清单内 |
| [rtl/framebuffer/frame_fifo_read.v](../../render/rtl/framebuffer/frame_fifo_read.v) | `frame_fifo_read` | 未列入 |
| [rtl/framebuffer/frame_fifo_read_dual.v](../../render/rtl/framebuffer/frame_fifo_read_dual.v) | `frame_fifo_read_dual` | 清单内 |
| [rtl/framebuffer/frame_fifo_write.v](../../render/rtl/framebuffer/frame_fifo_write.v) | `frame_fifo_write` | 清单内 |
| [rtl/framebuffer/frame_read_write.v](../../render/rtl/framebuffer/frame_read_write.v) | `frame_read_write` | 清单内 |
| [rtl/framebuffer/rgb888_word_packer.v](../../render/rtl/framebuffer/rgb888_word_packer.v) | `rgb888_word_packer` | 未列入 |
| [rtl/framebuffer/rgb888_word_reader.v](../../render/rtl/framebuffer/rgb888_word_reader.v) | `rgb888_word_reader` | 清单内 |
| [rtl/framebuffer/sdram_app_arb.v](../../render/rtl/framebuffer/sdram_app_arb.v) | `sdram_app_arb` | 清单内 |
| [rtl/framebuffer/sdram_app_mux.v](../../render/rtl/framebuffer/sdram_app_mux.v) | `sdram_app_mux` | 未列入 |
| [rtl/framebuffer/sdram_user_arb.v](../../render/rtl/framebuffer/sdram_user_arb.v) | `sdram_user_arb` | 未列入 |
| [rtl/link/db_async_fifo.v](../../render/rtl/link/db_async_fifo.v) | `db_async_fifo` | 清单内 |
| [rtl/link/db_ethernet.v](../../render/rtl/link/db_ethernet.v) | `db_ethernet` | 清单内 |
| [rtl/link/db_link.v](../../render/rtl/link/db_link.v) | `db_link`, `db_sequence_hold` | 清单内 |
| [rtl/link/db_mac_rx.v](../../render/rtl/link/db_mac_rx.v) | `db_mac_rx`, `db_management_word_fifo` | 清单内 |
| [rtl/link/db_packet_ram.v](../../render/rtl/link/db_packet_ram.v) | `db_packet_ram` | 清单内 |
| [rtl/link/vendor/IDDR.v](../../render/rtl/link/vendor/IDDR.v) | `IDDR` | 清单内 |
| [rtl/link/vendor/ODDR.v](../../render/rtl/link/vendor/ODDR.v) | `ODDR` | 清单内 |
| [rtl/link/vendor/rgmii_interface.v](../../render/rtl/link/vendor/rgmii_interface.v) | `rgmii_interface`, `db_rx_clk_buf` | 清单内 |
| [rtl/link/vendor/temac_block.v](../../render/rtl/link/vendor/temac_block.v) | `temac_block` | 清单内 |
| [rtl/link/vendor/tx_clk_en_gen.v](../../render/rtl/link/vendor/tx_clk_en_gen.v) | `tx_clk_en_gen` | 清单内 |
| [rtl/render_core.v](../../render/rtl/render_core.v) | `render_core` | 清单内 |
| [rtl/sdram/global_def.v](../../render/rtl/sdram/global_def.v) | 厂商加密实现 | 未列入 |
| [rtl/sdram/sdr_as_ram.enc.v](../../render/rtl/sdram/sdr_as_ram.enc.v) | `sdr_as_ram` | 清单内 |
| [rtl/sdram/sdr_init_ref.enc.v](../../render/rtl/sdram/sdr_init_ref.enc.v) | `sdr_init_ref` | 清单内 |
| [rtl/sdram/sdr_wrrd.enc.v](../../render/rtl/sdram/sdr_wrrd.enc.v) | 厂商加密实现 | 清单内 |
| [rtl/sdram/sdram.v](../../render/rtl/sdram/sdram.v) | `sdram` | 清单内 |
| [rtl/seam/db_audio_sink.v](../../render/rtl/seam/db_audio_sink.v) | `db_audio_sink` | 清单内 |
| [rtl/seam/seam_render.v](../../render/rtl/seam/seam_render.v) | `seam_render` | 清单内 |
| [rtl/top_render.v](../../render/rtl/top_render.v) | `top_render` | 清单内 |
| [rtl/ui/audio_osd_overlay.v](../../render/rtl/ui/audio_osd_overlay.v) | `audio_osd_overlay`, `resource_audio_glass_rg` | 清单内 |
| [rtl/ui/audio_osd_status.v](../../render/rtl/ui/audio_osd_status.v) | `audio_osd_status` | 未列入 |
| [rtl/ui/calendar_clock.v](../../render/rtl/ui/calendar_clock.v) | `calendar_clock` | 清单内 |
| [rtl/ui/clock_overlay.v](../../render/rtl/ui/clock_overlay.v) | `clock_overlay`, `resource_clock_characters`, `resource_clock_palette`（另1个附属模块） | 清单内 |
| [rtl/ui/clock_view_cdc.v](../../render/rtl/ui/clock_view_cdc.v) | `clock_view_cdc` | 清单内 |
| [rtl/ui/db_audio_model.v](../../render/rtl/ui/db_audio_model.v) | `db_audio_model` | 清单内 |
| [rtl/ui/font_rom.v](../../render/rtl/ui/font_rom.v) | `font_rom`, `resource_font_middle`, `resource_font_edges` | 清单内 |
| [rtl/ui/image_overlay_64.v](../../render/rtl/ui/image_overlay_64.v) | `image_overlay_64` | 清单内 |
| [rtl/ui/osd_paint_anim.v](../../render/rtl/ui/osd_paint_anim.v) | `osd_paint_anim` | 清单内 |
| [rtl/ui/osd_paint_bar.v](../../render/rtl/ui/osd_paint_bar.v) | `osd_paint_bar` | 清单内 |
| [rtl/ui/osd_paint_icon.v](../../render/rtl/ui/osd_paint_icon.v) | `osd_paint_icon` | 清单内 |
| [rtl/ui/osd_paint_text.v](../../render/rtl/ui/osd_paint_text.v) | `osd_paint_text`, `resource_audio_compact9` | 清单内 |
| [rtl/ui/osd_timebase.v](../../render/rtl/ui/osd_timebase.v) | `osd_timebase` | 清单内 |
| [rtl/ui/sd_subtitle_view.v](../../render/rtl/ui/sd_subtitle_view.v) | `sd_subtitle_view` | 清单内 |
| [rtl/ui/subtitle_ram.v](../../render/rtl/ui/subtitle_ram.v) | `subtitle_ram` | 清单内 |
| [rtl/ui/text_osd_controller.v](../../render/rtl/ui/text_osd_controller.v) | `text_osd_controller` | 清单内 |
| [rtl/ui/text_osd_event_router.v](../../render/rtl/ui/text_osd_event_router.v) | `text_osd_event_router` | 清单内 |
| [rtl/ui/text_osd_overlay.v](../../render/rtl/ui/text_osd_overlay.v) | `text_osd_overlay`, `resource_text_background_rg`, `resource_text_background_b`（另3个附属模块） | 清单内 |
| [rtl/ui/text_osd_ram.v](../../render/rtl/ui/text_osd_ram.v) | `text_osd_ram` | 清单内 |
| [rtl/ui/text_osd_view_cdc.v](../../render/rtl/ui/text_osd_view_cdc.v) | `text_osd_view_cdc` | 清单内 |
| [rtl/ui/ui_text_overlay.v](../../render/rtl/ui/ui_text_overlay.v) | `ui_text_overlay`, `resource_ui_channel`, `resource_ui_background`（另6个附属模块） | 清单内 |
| [rtl/ui/volume_hint_controller.v](../../render/rtl/ui/volume_hint_controller.v) | `volume_hint_controller` | 清单内 |
| [rtl/ui/volume_overlay.v](../../render/rtl/ui/volume_overlay.v) | `volume_overlay` | 清单内 |
| [rtl/video/brightness_scale.v](../../render/rtl/video/brightness_scale.v) | `brightness_scale` | 清单内 |
| [rtl/video/color_bar.v](../../render/rtl/video/color_bar.v) | `color_bar` | 清单内 |
| [rtl/video/contrast_adjust.v](../../render/rtl/video/contrast_adjust.v) | `contrast_adjust` | 清单内 |
| [rtl/video/error_overlay.v](../../render/rtl/video/error_overlay.v) | `error_overlay` | 清单内 |
| [rtl/video/mix_alpha_ctrl.v](../../render/rtl/video/mix_alpha_ctrl.v) | `mix_alpha_ctrl` | 清单内 |
| [rtl/video/mix_transition_ctrl.v](../../render/rtl/video/mix_transition_ctrl.v) | `mix_transition_ctrl` | 清单内 |
| [rtl/video/pixel_mixer.v](../../render/rtl/video/pixel_mixer.v) | `pixel_mixer` | 清单内 |
| [rtl/video/saturation_adjust.v](../../render/rtl/video/saturation_adjust.v) | `saturation_adjust` | 清单内 |
| [rtl/video/video_stream_reg.v](../../render/rtl/video/video_stream_reg.v) | `video_stream_reg` | 清单内 |
| [rtl/video/video_timing_data.v](../../render/rtl/video/video_timing_data.v) | `video_timing_data` | 清单内 |

头文件：[rtl/link/db_crc.vh](../../render/rtl/link/db_crc.vh)、[rtl/pkg/board_link.vh](../../render/rtl/pkg/board_link.vh)、[rtl/pkg/fat_dir_bus.vh](../../render/rtl/pkg/fat_dir_bus.vh)、[rtl/pkg/fat_err_codes.vh](../../render/rtl/pkg/fat_err_codes.vh)、[rtl/pkg/osd_model_bus.vh](../../render/rtl/pkg/osd_model_bus.vh)、[rtl/pkg/text_osd_model.vh](../../render/rtl/pkg/text_osd_model.vh)、[rtl/pkg/video_bmp_params.vh](../../render/rtl/pkg/video_bmp_params.vh)、[rtl/ui/font_audio_rows.vh](../../render/rtl/ui/font_audio_rows.vh)、[rtl/ui/font_blend.vh](../../render/rtl/ui/font_blend.vh)、[rtl/ui/font_diag_rows.vh](../../render/rtl/ui/font_diag_rows.vh)。

## 保留代码与验证入口

- media的 `clock/sys_pll.v`、`glue/glue_video_ctrl.v` 未列入主构建。core中bank0/lba_stream0是绑空闲的预留，不代表视频文件解码功能。
- render的 `clock/sys_pll.v`、旧单路frame_fifo_read、rgb888_word_packer、sdram_app_mux、sdram_user_arb、audio_osd_status等未列入主构建；主输出用frame_fifo_read_dual及db_audio_model。startup_pulse列入清单但HDMI封装未例化它，EDID触发固定关闭。
- `audio_fft_osd.v`有兼容模块audio_fft_osd，但顶层实际选择audio_goertzel_osd。color_bar用于产生扫描时序，RGB彩条输出未接到正常主画面。
- `al_ip/TEMAC_CORE.ipc`引用本板TEMAC网表；link/vendor提供RGMII、IDDR/ODDR及时钟使能封装，两板链路可有独立优化，协议宏保持一致。
- `diag/sources.txt`及独立.al定义PRBS工程；`sim/run.ps1`按测试名选择RTL/原语模型；tools/dual-board/run-system.ps1临时重命名render链路标识来联合实例化两份实现。
- 主构建不读取根目录单板RTL、ref_extract、_apug011、历史evidence里的门级副本；build/Runs内实验生成文件也不能按目录存在就计入功能。

结构与依赖检查：`python tools/dual-board/audit.py`。完整系统仿真、专项用例和实板证据的范围不同，运行入口见两板README，开发与验证结果记入[独立记录](development-history.md)。
