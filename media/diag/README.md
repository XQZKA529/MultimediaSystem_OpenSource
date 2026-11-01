# 双向 PRBS31 实板链路诊断

从 `media/` 目录执行下面的命令；使用 PowerShell 7（pwsh），构建工具为 Tang Dynasty 6.2.168116。

本目录是独立诊断工程，使用本板PLL、引脚、厂商RGMII/TEMAC，不含SD卡、SDRAM、图片、音频及可靠业务端点。仅用于检验物理链路连续收发；完整功能项目须单独验收。media/render各自装载对应诊断bit，两板网线直连，PHY必须为千兆全双工。

```powershell
$env:TD_ROOT='D:/AnLu_FPGA_environment'
$env:MODELSIM_BIN='D:/Quartus_Standard/Quartus_Standard/modelsim_ase/win32aloem'
./diag/sim.ps1
./diag/run.ps1 -Stage all -RunTag mac
./diag/check-reports.ps1 -RunDir ./Runs/linktest/phy_mac
```

顶层 `top_linktest_media`，工程 `MultimediaSystem_media_linktest.al`，产物 `Runs/linktest/phy_mac/MultimediaSystem_media_linktest.bit`。复制或改名后先运行 `./diag/run.ps1 -Stage project`。完整功能顶层仍用 `build/run.ps1`，互不修改工程入口。诊断源码清单为本目录 `sources.txt`，指纹覆盖实际依赖、include和IPC网表，不依赖本板存储/显示实现。诊断也执行最终资源、setup/hold和输入指纹检查；诊断通过不代表完整功能配置通过。

帧为目标MAC6B、源MAC6B、EtherType **0x88B6**、大端序号4B、ASCII `PRB1`4B、1024B图案；MAC生成/校验FCS。每帧独立种子 `(sequence XOR (role * 0x01234567)) AND 0x7FFFFFFF`，零替换成1。31位状态每次取高8位为字节，然后移位8次，每次新低位=旧bit30 XOR 旧bit27，角色media=1/render=2。它是独立诊断格式，不是业务协议0x88B5。

TEMAC客户端只有首字节握手，之后连续发送。接收端逐字节校验MAC、类型、magic、图案、长度，并读取MAC的FCS状态。帧序号用于观察丢包/复位事件，不执行重传。上电及PHY恢复后的首帧重新建立序号基准。

virtualIO探测点：

| 探测点 | 时钟域 | 意义 |
|---|---|---|
| DBG_LINK_UP | bus_clk | PHY千兆全双工状态 |
| DBG_TX_FRAMES/DBG_TX_BYTES | mem_tx_clk | 已交给MAC的帧数/图案字节数 |
| DBG_RX_FRAMES/DBG_RX_BYTES | rgmii_rx_clk | FCS、长度、图案均通过的帧数/字节数 |
| DBG_FCS_ERRORS | rgmii_rx_clk | MAC错误帧 |
| DBG_PATTERN_ERRORS | rgmii_rx_clk | 包头或PRBS不匹配 |
| DBG_LENGTH_ERRORS | rgmii_rx_clk | 客户端长度不是1046B |
| DBG_SEQUENCE_GAPS | rgmii_rx_clk | 成功帧序号不连续 |
| DBG_ERROR | rgmii_rx_clk | 前三类错误保持到本板复位 |

计数器32位；图案字节数为42位（帧数左移10），足够一小时千兆测试。跨域计数器不作为控制输入；采集时选择对应时钟域，不能把每位异步读取当成一致快照。LED1=链路就绪且未见数据/FCS/长度错误。计数器通过ChipWatcher观察；插入探针后的调试bit需重新构建并记录资源/时序。

建立链路后记录两方向起始计数和时间，运行至少一小时，再记录结束值。有效负载速率=8×接收图案字节增量/秒；media RX和render RX分别测量，发送计数仅表示交给MAC。稳定区间无复位、无拔线，应满足FCS/图案/长度/序号异常计数不增加；记录实际吞吐，不以125MHz时钟推断达到了线速。专门拔线/复位场景另记，可能产生短帧、FCS错或序号间断。

[仿真用例](tb_prbs.v)覆盖双向连续帧、字节序、独立PRBS参考向量、图案/FCS/短帧错误注入、PHY断连恢复和计数。它模拟MAC客户端，不替代模拟电气、厂商MAC/FCS和实板一小时长测。

完整系统的功能与接线见[主 README](../../README.md)，开发及实测记录统一见[开发记录](../../doc/dual-board/development-history.md)。本诊断不执行业务协议的ACK重传或图片/音频验收。
