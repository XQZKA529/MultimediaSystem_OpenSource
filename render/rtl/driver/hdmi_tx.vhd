-----------------------------------------------------------------------------
-- 文件名 : rtl/driver/hdmi_tx.vhd
-- 作  用 : 【驱动层 VHDL 封装】
--          将 Verilog 侧的 VGA 风格接口，映射到安路官方加密 IP
--          DVITransmitter（内部完成 TMDS 编码 + LVDS 串化）。
--
-- 端口约定（务必与 rtl/driver/hdmi_driver.v 保持一致）：
--   VGA_RGB(23 downto 16) = RED    红
--   VGA_RGB(15 downto  8) = GREEN  绿
--   VGA_RGB( 7 downto  0) = BLUE   蓝
--
-- 时钟：
--   PXLCLK_I    : 像素时钟（并行域）
--   PXLCLK_5X_I : 5 倍像素时钟（串化域，10bit 字符用双沿 DDR 发送）
--
-- 复位：
--   RST_N : 低电平有效
--
-- 注意：VHDL 注释只能用 --，不能使用 // 或 /* */
-----------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.std_logic_arith.all;

entity hdmi_tx is
    Generic (FAMILY : STRING := "EG4");
    Port (
        PXLCLK_I    : in  STD_LOGIC;
        PXLCLK_5X_I : in  STD_LOGIC;
        RST_N       : in  STD_LOGIC;

        -- 并行 VGA 风格输入
        VGA_HS      : in  std_logic;
        VGA_VS      : in  std_logic;
        VGA_DE      : in  std_logic;
        VGA_RGB     : in  std_logic_vector(23 downto 0);

        -- HDMI / TMDS 串行输出（正端）
        HDMI_CLK_P  : out STD_LOGIC;
        HDMI_D2_P   : out STD_LOGIC;
        HDMI_D1_P   : out STD_LOGIC;
        HDMI_D0_P   : out STD_LOGIC
    );
end hdmi_tx;

architecture Behavioral of hdmi_tx is

    -- 安路加密 IP 实体声明（源文件 DVITransmitter.enc.vhd）
    component DVITransmitter is
        Generic (FAMILY : STRING := "PH1");
        Port (      
            RED_I        : in  STD_LOGIC_VECTOR (7 downto 0);
            GREEN_I      : in  STD_LOGIC_VECTOR (7 downto 0);
            BLUE_I       : in  STD_LOGIC_VECTOR (7 downto 0);
            HS_I         : in  STD_LOGIC;
            VS_I         : in  STD_LOGIC;
            VDE_I        : in  STD_LOGIC;
            RST_I        : in  STD_LOGIC;
            PCLK_I       : in  STD_LOGIC;
            PCLK_X5_I    : in  STD_LOGIC;
            TMDS_TX_CLK_P: out STD_LOGIC;
            TMDS_TX_2_P  : out STD_LOGIC;
            TMDS_TX_1_P  : out STD_LOGIC;
            TMDS_TX_0_P  : out STD_LOGIC
        );
    end component;

begin

    -- 通道映射关系（DVI 标准）：
    --   TMDS_TX_2_P ← 红 R
    --   TMDS_TX_1_P ← 绿 G
    --   TMDS_TX_0_P ← 蓝 B，并在消隐期携带 HS/VS 控制字符
    Inst_DVITransmitter : DVITransmitter
        GENERIC MAP (
            FAMILY => FAMILY
        )
        PORT MAP (
            RED_I         => VGA_RGB(23 downto 16),
            GREEN_I       => VGA_RGB(15 downto 8),
            BLUE_I        => VGA_RGB(7 downto 0),
            HS_I          => VGA_HS,
            VS_I          => VGA_VS,
            VDE_I         => VGA_DE,
            RST_I         => RST_N,
            PCLK_I        => PXLCLK_I,
            PCLK_X5_I     => PXLCLK_5X_I,
            TMDS_TX_CLK_P => HDMI_CLK_P,
            TMDS_TX_2_P   => HDMI_D2_P,
            TMDS_TX_1_P   => HDMI_D1_P,
            TMDS_TX_0_P   => HDMI_D0_P
        );

end Behavioral;
