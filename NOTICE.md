# 第三方组件与发布说明

本目录是从 v1 开发仓库导出的开源版快照（`dual_board_main` 分支，提交 `2538b23`）。为了让包体保持可读、可构建，已剔除构建产物、仿真产物、示例素材与厂商文档。

## 厂商 IP（再分发前请确认条款）

- `media/al_ip/`、`render/al_ip/` 下的 `TEMAC_CORE.ipc` 与 `TEMAC_CORE_gate.v` 由安路 Tang Dynasty 生成，是构建必需件。
- `render/rtl/driver/hdmi_1_4b_transmitter_core_wrapper.enc.v` 等为安路 HDMI IP 的加密交付件，同样是构建必需件。
- 上述文件的再分发与商用受安路科技许可约束；公开发布前请自行确认授权范围。

## 第三方字体

- `render/doc/font-license.txt`、`tools/dual-board/fonts/LICENSE.txt`：字模/字体素材随附的 Bitstream Vera / DejaVu 许可，使用时请保留。

## 本包未包含

- `test_audio/`（含版权音乐）与 `fpga_bmp_1280x720/`（标准测试图）等示例素材，请自备；格式要求见 `README.md`。
- `_apug011/`、`doc/refs/`、`doc/reference/` 等安路/板卡厂商文档。
- 构建报告与仿真证据（`Runs/`、`build/evidence/`、`log/`）、ChipWatcher 配置、旧单板基线。
- 生成的项目文件（`*.al`）：在 `media/`、`render/` 下执行 `build/run.ps1 -Stage project` 可重新生成。

## 签核 bit

- `release/Second_Release_682b0ab/` 内为第二次签核的两板 bit 与 SHA256SUMS，按现状提供，仅供开发与验收参考；对应的时序报告不在本包中。

## 许可证

本仓库暂未附项目级 LICENSE，发布者确定后再补充。README 中引用的 `Runs/` 报告路径与本包内不存在的旧 zip 均属私有仓库内容，可忽略；文档里的 `evidence/` 图片与报告也已随产物剔除，相关链接可能失效。`README.md`、`doc/README.md`、`doc/dual-board/development-history.md` 中指向 `Runs/`、`evidence/`、`build/*.zip`、`release/First_Release_8a46c85/`、`handover-*` 与 `*.al` 的链接同理，本包内不可用或需重新生成。
