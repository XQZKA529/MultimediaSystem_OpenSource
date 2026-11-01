# RTL 与实际 TEMAC 网表独立排查（2026-10-07）

输入现象：render 在 LINK DOWN / WAIT DATA 间反复切换；SD 卡在 media，
同一卡及文件用单板工程可显示；用户确认实物 PHY 为 RTL8211E。
本结论依据当前源码、实际 TEMAC gate netlist 和本轮新运行的测试，不采用旧排障记录的推断。

## 1. 可复现的链路缺陷：TEMAC 地址过滤配置字节序错误

`db_link` 的线缆 MAC 使用网络字节序：media=02:00:00:00:00:01，
render=02:00:00:00:00:02。`db_ethernet` 原把 `LOCAL_MAC` 原值直接传给
`temac_block.unicast_address`。实际 TEMAC 的该配置口要求字节反序。

render 的地址恰好是字节回文，反序前后相同；media 的地址不是。因此前向
media→render 帧能通过硬件地址过滤，反向 render→media 帧被 MAC 过滤。
后者不一定产生 rx_error_frame：地址过滤丢弃和 FCS 错误不是同一事件。

使用项目的 `al_ip/TEMAC_CORE_gate.v` 和 TD 原语模型进行 GMII 环回，旧配置结果：

```
up=01 completed=0 MAC good=2/0 rxerr=0
FAIL watchdog at 500 us
```

该测试没有 SD、FAT 或图片源，单向握手故障仍然存在。
结合 `db_link`：media 没收到 HELLO，不能建立自己的会话，也不会发送业务 STATUS；
render 收到 media 定期 HELLO，可短暂建立会话，但得不到反向 ACK。
若 render 有待确认业务包，5ms 重试间隔、最多三次重传后会结束会话；
无业务包时仍可能被同一方向的后续 HELLO 保活。
因此具体闪烁周期依赖当时业务状态，不能把观察到的 LED 频率直接等同于协议定时器。

修复：两板 `db_ethernet.v` 仅在 TEMAC 配置边界反序六个字节；
`db_link` 的线上地址和协议保持网络序。
厂商原始 RTL 的独立佐证为资料包千兆例程 `udp_transmit_test.v` 的
`unicast_address={LOCAL_MAC_ADDRESS[7:0],...,LOCAL_MAC_ADDRESS[47:40]}`。

修复后的 `tb_temac_gate` 直接测试生产 `db_ethernet`、`db_link`、实际 TEMAC 网表，
仅把 RGMII/时钟外壳替换成理想 GMII 环回。两板本地版本均通过：
双向 HELLO、1024字节数据逐字校验、FCS、协议 CRC、累计 ACK，重传和接收拒绝为0。
该测试不验证 PCB 电气、RGMII 采样相位或实物 PHY 协商。

## 2. 可复现的图片读取缺陷：BMP 文件头被远端图片 credit 阻塞

单板与 media 的五个 SD 核心文件逐字节相同：`sd_card_sdio`、`sdio_core`、
`sdio_cmd`、`sdio_phy`、`sd_crc`。初始化序列仍在本地运行。
顶层实例的采样参数不同：单板 SAMPLE_DLY=0、当前 media=1；
本轮不以未经电气实测的相位猜测代替下面已复现的逻辑故障。

启动顺序：FAT挂载→目录→512字节文件头探测→校验→image_req→IMG_BEGIN→
render回复IMG_READY→整图像素读取。

当前拆分的错误连接形成循环：

```
文件头探测需要 file_read_ready
file_read_ready <- media_core.video_write_sector_ready <- seam.image_burst_ready
image_burst_ready = link_up && image_ready && img_free >= 528
image_ready 需要收到 IMG_READY
IMG_READY 需要先发 IMG_BEGIN
IMG_BEGIN 需要先发 image_req
image_req 需要文件头探测完成
```

SD/FAT 可以已经正常挂载和列目录，却无法读文件头。单板的 SDRAM FIFO 空时
write_sector_ready 可以立即为1，没有这一远端事务依赖。

修复 `media_core`：`video_write_sector_ready=(file_read_limit!=0) || image_burst_ready`。
非零 limit 是现有 BMP 控制器的有界头探测（512字节），该阶段不输出像素；
整文件读取的 limit 为0，继续严格按远端 credit 节流。

`tb_media_sd_boot` 使用生产 media_core、FAT32、BMP控制器、seam_media，
以确定的 FAT32/BMP 扇区模型替代 SD 物理控制器。旧连接的单独副本复现：

```
bmp=4 fat=30 limit=512 credit=0
Fatal: SD boot deadlock (500 us)
```

同一测试修复后通过：render离线时完成挂载、目录和文件头并停在WAIT_WR；
收到IMG_READY前无像素读取；收到后开始输出像素；注入SD初始化ERROR7时，
仍发送含ERROR7的STATUS。因此 WAIT DATA 表示远端状态尚未送达，不能直接当作
“SD读取失败”或“SD无文件”；单纯SD失败也不是协议会话掉线的必要条件。

## 3. 本轮验证与上板边界

通过：media/render `tb_temac_gate`；media `tb_media_sd_boot`、`tb_media_source`、
`tb_fat32_ro`、`tb_phy_status`；源码本地依赖/单板基线审计。
之前在本次排查中重新运行的 render `tb_link`、`tb_phy_status`、
`tb_session_stability` 也通过，但简化MAC测试没有覆盖实际硬件地址过滤。

生产改动只有两板 MAC 配置字节序、media 图片读取 credit 选择，外加测试和测试注册。
未生成本次修改的生产 bit，未声称完成实板验证。

现有 GUI 报告：media(18:35) setup WNS=-0.240ns，
render(18:32) setup WNS=-0.352ns；两板 RX hold WNS=-2.645ns。
render setup 端点包括链路CRC发送控制；RX hold 是输入PAD寄存器采样路径。
这属于尚待解决的时序问题，不能由本轮功能仿真签核。
报告已显示 RXC 经 GCLK；R-Period 小于约束周期表示内部 setup 有余量，
不能据此判定时钟网络错误。

必须两板从 Syn 重新构建，再烧录本次完整功能 bit；现有 bit 不含本轮修复。
如果修复后屏幕会话仍闪烁，采集 phy_ok、session_reset、peer_age、
retry_seen/error_seen/drop_seen 并核对最终时序。PHY网口LED并非由本次会话FSM驱动，
其物理闪烁还应依据实际LED配置和PHY状态判定。


## 后续实板确认

2026-10-07 用户上板反馈：功能已全部恢复。本文保留本次独立分析和仿真证据；文中“尚未上板/编译”等表述描述排查当时的阶段，当前状态见 [实板记录](hardware-acceptance.md)。
