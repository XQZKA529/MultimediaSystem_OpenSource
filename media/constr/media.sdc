create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name rgmii_rx_clk -period 8.000 -waveform {0 4} [get_ports {rgmii_rxc}]
derive_clocks
rename_clock -name bus_clk -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[0]}]
rename_clock -name mem_tx_clk -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[1]}]
# The media board has no SDRAM; unused PLL output clkc[2] is optimized away.
rename_clock -name tx_clk_90 -source [get_ports {sys_clk}] -master_clock sys_clk [get_pins {u_sys_pll/pll_inst.clkc[3]}]
set_clock_groups -exclusive -group [get_clocks {rgmii_rx_clk}]
# ^ rgmii_rx_clk is declared -EXCLUSIVE, exactly as the vendor's working reference
#   does (33_.../ph1_constraints/ph1_demo.sdc:
#       set_clock_groups -exclusive -group [get_clocks {phy1_rgmii_rx_clk}] ).
#
#   Why not -asynchronous (what we had, and what the line below still does for
#   the other clocks): -asynchronous only removes CROSS-domain paths; it still
#   runs INTRA-clock analysis on rgmii_rx_clk, and that generates a phantom
#   hold check on the corner "input port -> its own input PAD".  The data pad
#   (rgmii_rx_ctl at T13) has 1.075ns of delay while the clock pad (rgmii_rxc
#   at T14) plus the global buffer needs 3.513ns, so the tool asserts the data
#   arrives 2.4ns "early" against a 0.000ns budget and reports
#   HWNS -2.645ns / 5 violated endpoints -- byte-identical on BOTH boards,
#   which is the tell that it is structural (shared rgmii_interface.v +
#   temac_block.v) and not board logic.
#
#   ★ MEASURED 2026-10-07: -exclusive ALONE IS NOT ENOUGH.  A full `-Stage all`
#     build with this exact line still reported HWNS -2645ps / 5 H-FEPS, and
#     final_timing.rpt shows the same "Begin: rgmii_rx_ctl (input port) / End:
#     rgmii_rx_ctl_syn_2.ipad / Budget 0.000ns / Logic Level 0 / Fanout 1"
#     shape.  TD 6.2 still emits this phantom check on the RX *input ports*
#     even when their clock is -exclusive, so the explicit -hold false path
#     below is required as well.
#
#   The check is meaningless in any case: the external PHY deliberately delays
#   RXD/RX_CTL relative to RXC (the RGMII 1Gbps 0.5..2.5ns window already
#   encoded by the set_input_delay -max below).  The capture relationship is a
#   pad-to-pad property of the PHY+PCB, which STA cannot and should not verify.
set_clock_groups -asynchronous -group [get_clocks bus_clk] -group [get_clocks {mem_tx_clk tx_clk_90}] -group [get_clocks sys_clk]
# Explicit pairs also cover TD's clock-group import differences. These clock
# boundaries use Gray FIFOs, local reset release, or held req/done mailboxes.
set_false_path -from [get_clocks bus_clk] -to [get_clocks rgmii_rx_clk]
set_false_path -from [get_clocks rgmii_rx_clk] -to [get_clocks bus_clk]
set_false_path -from [get_clocks bus_clk] -to [get_clocks mem_tx_clk]
set_false_path -from [get_clocks mem_tx_clk] -to [get_clocks bus_clk]
set_false_path -from [get_clocks rgmii_rx_clk] -to [get_clocks mem_tx_clk]
set_false_path -from [get_clocks mem_tx_clk] -to [get_clocks rgmii_rx_clk]

# --- RGMII RX input delays -------------------------------------------------
# NOW LARGELY REDUNDANT: with rgmii_rx_clk declared -exclusive above, paths into
# the RX IDDR are no longer analysed at all, so this -max no longer steers
# placement.  It is kept only as documentation of the PHY's 0.5..2.5ns window;
# do NOT respond to it by adding a matching -min.
#
# THERE IS NO -min LINE, DELIBERATELY.  A previous revision added
#   set_input_delay -clock rgmii_rx_clk -min 0.500 [get_ports {...}]
# and it charged a 0.5ns hold requirement against an input path that has no
# launch clock of its own (the PHY's internal TXC is not visible to STA).  The
# result was HWNS -2.145ns with 5 hold violations in the rgmii_rx_clk domain on
# both boards, while setup stayed at +0.168ns / 0 viol.  This is the exact trap
# already recorded in constr/hdmi_colorbar.sdc for the SD inputs ("不要再加
# set_min_delay ... 会让这条无发射时钟的输入路径以 hold 形式计入违规").
# The vendor RGMII reference constrains no input delay at all and merely marks
# the RX clock -exclusive.
set_input_delay -clock rgmii_rx_clk -max 2.500 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

# --- Kill the phantom HOLD check on the RX input ports ---------------------
# Even with rgmii_rx_clk -exclusive, TD 6.2 still builds a HOLD check whose
# begin point is the input PORT (rgmii_rx_ctl / rgmii_rxd[*]) and whose end
# point is that port's OWN input PAD, against Budget 0.000ns.  That is not a
# register-to-register path: there is no launch flop and no capture flop, just
# the PAD cell delay (1.075ns) measured against the RXC capture clock that
# arrives 3.513ns later through the global buffer -- so the tool calls the data
# 2.645ns "too early".  It is un-actionable (Logic Level 0, Fanout 1) and is
# byte-identical on both boards.
#
# Remove ONLY the hold half of that port->pad check; the setup capture path
# (RXD -> IDDR) stays analysed, which is the direction that actually matters.
# This is the same class of fix as the SD input case in
# constr/hdmi_colorbar.sdc, which refuses to add set_min_delay for exactly this
# reason.  Do NOT replace this with a -min input delay: that re-introduces the
# violation (it was measured at HWNS -2.145ns / 5 H-FEPS).
set_false_path -hold -from [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

# --- RGMII TX output delays ------------------------------------------------
# DELIBERATELY NOT CONSTRAINED.  A previous revision added
#   set_output_delay -clock mem_tx_clk -max 2.000 / -min -2.000
# and that was wrong: it charged 2.0ns of "external budget" against an 8ns
# (125MHz) period on a path whose dominant delay is the I/O cell itself, not
# logic (the failing path was rgmii_tx_ctl at Logic Level 0, Data Path Delay
# 5.2ns).  The result was Setup WNS -3.310ns / Hold WNS -2.145ns on both
# boards.  The vendor demo constrains no RGMII output delay either and declares
# the RX clock -exclusive, so TX outputs are left unconstrained to match.
#
# TXC-to-data skew is realised in the OUTPUT PAD, not by STA.  The vendor's
# LIVE ph1_demo.adc uses DRIVESTRENGTH=8 / IOSTANDARD=LVCMOS33 / PULLTYPE=NONE
# with NO SLEWRATE and NO OUTDEL on any RGMII TX pin, and media.adc/render.adc
# now match that exactly.  An earlier revision had copied the vendor's
# COMMENTED-OUT block for a different board (DRIVESTRENGTH=16, SLEWRATE=FAST)
# and put OUTDEL=3 on rgmii_txc only - an un-budgeted, asymmetric TXC-vs-data
# skew that eats the far-end capture eye at 125MHz DDR.  Do not reintroduce it.

set_max_delay 8.000 -from [get_ports {SD_CMD SD_DAT0 SD_DAT1 SD_DAT2 SD_DAT3}]
# RGMII pad delays/90-degree phase are imported from the vendor board reference.
# External PHY/PCB margins must be checked on hardware before release.
