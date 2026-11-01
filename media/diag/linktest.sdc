create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name rgmii_rx_clk -period 8.000 -waveform {0 4} [get_ports {rgmii_rxc}]
derive_clocks
rename_clock -name bus_clk -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[0]}]
rename_clock -name mem_tx_clk -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[1]}]
rename_clock -name mem_sft_clk -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[2]}]
rename_clock -name tx_clk_90 -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[3]}]
set_clock_groups -asynchronous -group [get_clocks bus_clk] -group [get_clocks {mem_tx_clk mem_sft_clk tx_clk_90}] -group [get_clocks rgmii_rx_clk] -group [get_clocks sys_clk]
# Explicit pairs also cover TD's clock-group import differences. These clock
# boundaries use Gray FIFOs, local reset release, or held req/done mailboxes.
set_false_path -from [get_clocks bus_clk] -to [get_clocks rgmii_rx_clk]
set_false_path -from [get_clocks rgmii_rx_clk] -to [get_clocks bus_clk]
set_false_path -from [get_clocks bus_clk] -to [get_clocks mem_tx_clk]
set_false_path -from [get_clocks mem_tx_clk] -to [get_clocks bus_clk]
set_false_path -from [get_clocks rgmii_rx_clk] -to [get_clocks mem_tx_clk]
set_false_path -from [get_clocks mem_tx_clk] -to [get_clocks rgmii_rx_clk]
# RGMII pad delays/90-degree phase are imported from the vendor board reference.
# External PHY/PCB margins must be checked on hardware before release.
