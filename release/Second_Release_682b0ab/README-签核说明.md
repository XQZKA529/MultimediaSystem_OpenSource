# 发布配对 Second_Release_682b0ab

源码提交：`682b0ab14712e401bc3ae345ef950a113dfae1f6`
器件：EG4S20BG256；业务协议：1.14；两板配套使用。
生成日期：2026-11-01

本目录固化该提交的两颗bit、最终QoR和输入指纹，资源与时序仅适用于该配对。TD可在bit头部写入构建时间，重新生成的文件SHA256不保证相同；校验本包时使用下表和SHA256SUMS.txt。输入指纹是原始字节SHA256，包含换行，必须按构建现场文件核对。

## 文件

| 文件 | 说明 | SHA256 |
|---|---|---|
| `MultimediaSystem_render_100MHz_682b0ab.bit` | render 板 | `529997e7ce0b0946e032b11fefcfca1afa55cd32f5bd612b1144b42ff070da3d` |
| `MultimediaSystem_media_50MHz_682b0ab.bit` | media 板 | `d3ffcf3e84d4086aede2ad323fb13ab6dc951ed6d04fe2f249807947421ca282` |

同目录附 `render_final.qor`、`media_final.qor` 与两板 `inputs.json`（构建输入指纹）。

## 时序与资源

| 指标 | render | media |
|---|---:|---:|
| Setup WNS / TNS / 违例端点 | +0.104 ns / 0 / 0 | +0.272 ns / 0 / 0 |
| Hold WNS / TNS / 违例端点 | +0.022 ns / 0 / 0 | +0.030 ns / 0 / 0 |
| Slice | 9,605 / 9,800（98.01%） | 9,402 / 9,800（95.94%） |
| BRAM9K / BRAM32K | 64 / 16 | 51 / 5 |
| DSP | 29 | 25 |
| Bitstream CRC | `01011` | `00101000110` |
| `check-reports.ps1` | QUALIFIED | QUALIFIED |

## 构建参数

render：

```powershell
./render/build/run.ps1 -Stage all -RunTag ce_rep `
  -InferFsm off -AreaEffort high -PhysicalEffort medium -PlaceSeed 6
```

media（先 syn，复制成 `_9`，再 phy）：

```powershell
./media/build/run.ps1 -Stage syn -RunTag final1msc `
  -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 3 -NoPostPlaceOpt
Copy-Item -Recurse media/Runs/syn_final1msc media/Runs/syn_final1msc_9
./media/build/run.ps1 -Stage phy -RunTag final1msc_9 `
  -AreaEffort medium -ShareArithmetic -MinRippleLength 16 -PlaceSeed 9 -NoPostPlaceOpt
```

该配置保留 `-NoPostPlaceOpt`。脚本要求phy与父syn使用相同RunTag，示例复制目录只为复用seed3综合结果并以seed9布线；`_9`并非脚本强制命名规则。也可用同一新RunTag先syn再phy，并保持相同综合选项。

## 复现步骤

1. **准备源码**：克隆仓库并切到该提交，工作树必须干净（构建指纹会比对源码）。

   ```powershell
   git checkout 682b0ab14712e401bc3ae345ef950a113dfae1f6
   git status --short        # 输出为空
   ```

2. **环境**：TD 6.2.168116，单实例工具，构建前确认没有其它 TD 进程（`tasklist | findstr td_commands_prompt`）；两板不要同时构建。

   ```powershell
   $env:TD_ROOT='D:/AnLu_FPGA_environment'
   $env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
   ```

3. **render**：执行上面的 render 命令，产物在 `render/Runs/phy_<tag>/MultimediaSystem_render.bit`。

4. **media**：按顺序执行 syn、复制、phy，产物在 `media/Runs/phy_final1msc_9/MultimediaSystem_media.bit`。

5. **签核校验**（必须用 pwsh 7）：

   ```powershell
   pwsh -NoProfile -File render/build/check-reports.ps1 -RunDir ./render/Runs/phy_ce_rep
   pwsh -NoProfile -File media/build/check-reports.ps1 -RunDir ./media/Runs/phy_final1msc_9
   ```

   两者都应输出 `QUALIFIED`，并核对 `final.qor` 的 Setup/Hold 为零违例、Slice 与上表一致。

6. **校验包内文件**：在本发布目录执行以下命令，输出应与SHA256SUMS.txt一致。重新构建的bit需独立核对其输入、QoR及完整载荷；短Bitstream CRC不能替代SHA256或完整载荷比对。

   ```powershell
   Get-FileHash -Algorithm SHA256 ./MultimediaSystem_media_50MHz_682b0ab.bit
   Get-FileHash -Algorithm SHA256 ./MultimediaSystem_render_100MHz_682b0ab.bit
   ```

运行check-reports.ps1需要PowerShell7；TD两板构建顺序执行。完整功能、素材、接线与操作见[系统 README](../../README.md)，发布构建过程和参照bit比较已移至[开发记录](../../doc/dual-board/development-history.md)。
