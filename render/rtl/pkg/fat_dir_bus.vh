//=============================================================================
// fat_dir_bus.vh — FAT 目录枚举契约的捆绑位分配（E1）
//
// 目录枚举的 entry 数据面（storage_service → glue_storage → top →
// file_browser / fat_bmp_controller）以一条宽向量过端口，取代原先
// 每层 10 个逐信号端口。切片宏是位分配的**唯一出处**：
//
//   dir_dat[`VDIR_D_CHAR]   目录名当前字符（8b）
//   dir_dat[`VDIR_D_INDEX]  name_index（8b）
//   dir_dat[`VDIR_D_FCLUST] entry_first_cluster（32b）
//   dir_dat[`VDIR_D_SIZE]   entry_size（32b）
//   dir_dat[`VDIR_D_ESTART] entry_start 脉冲（1b）
//   dir_dat[`VDIR_D_NVLD]   name_valid（1b）
//   dir_dat[`VDIR_D_EEND]   entry_end 脉冲（1b）
//   dir_dat[`VDIR_D_ISDIR]  entry_is_dir（1b）
//   dir_dat[`VDIR_D_DONE]   dir_done 脉冲（1b）
//   dir_dat[`VDIR_D_OK]     dir_ok（1b）
//
// ★ 宏内容是**裸索引范围**（不带方括号），使用处统一写
//   dir_dat[`VDIR_D_XXX]——展开即 dir_dat[79:72] 等，双工具验证过的写法。
//
// 请求侧握手（dir_req / dir_gnt / dir_start）有仲裁语义，保持独立端口，
// **不进**捆绑。
//
// ★ 位分配冻结：下位 86 位一经发布不再改动（TB 与综合产物依赖）。
//   新字段一律从 VDIR_DBUS_W 尾部追加并同步加宽 DBUS_W。
//
// include 路径约定：rtl/ 子目录内用 `include "../pkg/fat_dir_bus.vh"；
// 顶层用 `include "pkg/fat_dir_bus.vh"（TD 与 ModelSim 双验证过的模式）。
//=============================================================================
`ifndef FAT_DIR_BUS_VH
`define FAT_DIR_BUS_VH

`define VDIR_DBUS_W    86

`define VDIR_D_SIZE    31:0       // [31:0]   entry_size
`define VDIR_D_FCLUST  63:32      // [63:32]  entry_first_cluster
`define VDIR_D_INDEX   71:64      // [71:64]  name_index
`define VDIR_D_CHAR    79:72      // [79:72]  name_char
`define VDIR_D_ESTART  80         // [80]     entry_start
`define VDIR_D_NVLD    81         // [81]     name_valid
`define VDIR_D_EEND    82         // [82]     entry_end
`define VDIR_D_ISDIR   83         // [83]     entry_is_dir
`define VDIR_D_DONE    84         // [84]     dir_done
`define VDIR_D_OK      85         // [85]     dir_ok

`endif // FAT_DIR_BUS_VH
