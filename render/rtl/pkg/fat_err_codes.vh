//=============================================================================
// fat_err_codes.vh — fat32_ro 错误码唯一出处（fat_error_code 8bit 编码）
//
//  编码语义归属 fat32_ro（经 fail_operation(code) task 统一赋值）；
//  上层（storage_service / glue_storage / fat_bmp_controller 上屏）只允许
//  引用这里的宏，禁止再写 8'dN 裸数字比较。码值与既有上屏/调试口兼容，
//  只能追加不能改动。
//=============================================================================
`ifndef FAT_ERR_CODES_VH
`define FAT_ERR_CODES_VH

`define FAT_E_RD         8'd1   // SD 块读返回 blk_error（任意 op 底层读失败）
`define FAT_E_MBR        8'd2   // 挂载失败：MBR/分区/FS 签名不认
`define FAT_E_BPS        8'd3   // BPB 字节扇区数非 512
`define FAT_E_DIR_NM     8'd4   // 目录操作时未挂载
`define FAT_E_DIR_HOPS   8'd5   // 目录路径 hops 超限
`define FAT_E_FILE_BAD   8'd6   // 文件读未挂载 / 首簇非法
`define FAT_E_CLUSTER    8'd7   // 非法簇值（EOC 提前）
`define FAT_E_NDATA      8'd8   // 非 data cluster
`define FAT_E_CYCLE      8'd9   // 簇链环（Brent）/hop 超限
`define FAT_E_TIMEOUT    8'd10  // IO 超时
`define FAT_E_ABORT      8'd11  // 用户 abort
`define FAT_E_MAP_FULL   8'd12  // map 队满拒收
`define FAT_E_MAP_OVF    8'd13  // map 段表溢出

`endif // FAT_ERR_CODES_VH
