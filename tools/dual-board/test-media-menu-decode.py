"""Compare both new menu ROM implementations against a frozen original ROM.

Exhaust all page/mode/row/column inputs, explicit status banks and the X/Z
fallback contract, while changing addresses every clock to check latency.
"""
import argparse
from pathlib import Path

from resource_sim import simulate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    board = args.board.resolve()
    work = args.evidence.resolve()
    work.mkdir(parents=True, exist_ok=True)
    relative = 'rtl/ui/settings_menu_text_rom.v'
    original = (args.reference / relative).read_text(encoding='utf-8-sig')
    candidate = (board / relative).read_text(encoding='utf-8-sig')
    old_file = work / 'settings_reference.v'
    old_file.write_text(original.replace('module settings_menu_text_rom(',
                                        'module settings_menu_text_reference('), encoding='utf-8')
    hardware = work / 'settings_hardware.v'
    hardware.write_text(candidate.replace('settings_menu_row_decode', 'settings_menu_row_decode_hw')
                        .replace('module settings_menu_text_rom(', 'module settings_menu_text_rom_hw(')
                        .replace('`ifdef DB_BEHAVIORAL_RAM', '`ifdef FORCE_MENU_BEHAVIORAL_NEVER'),
                        encoding='utf-8')
    tb = work / 'tb_menu_decode.v'
    tb.write_text('''`timescale 1ns/1ps
module tb_menu_decode;
reg clk=0;always #5 clk=~clk;
reg status_bank=0;reg [3:0] page=0,row=0;reg [1:0] mode=0;reg [4:0] col=0;
wire [7:0] original,behavioral,physical;
integer n;
settings_menu_text_reference golden(.clk(clk),.status_bank(status_bank),.page(page),
 .mode(mode),.row(row),.col(col),.data(original));
settings_menu_text_rom candidate(.clk(clk),.status_bank(status_bank),.page(page),
 .mode(mode),.row(row),.col(col),.data(behavioral));
settings_menu_text_rom_hw hardware(.clk(clk),.status_bank(status_bank),.page(page),
 .mode(mode),.row(row),.col(col),.data(physical));
initial begin
 repeat(30) @(negedge clk);
 for(n=0;n<131073;n=n+1) begin
  @(negedge clk);
  {page,mode,row,col}=n[14:0];
  if(n<65536) status_bank=n[15];
  else if(n<98304) status_bank=1'bx;
  else status_bank=1'bz;
  @(posedge clk);#1;
  if(n>=1 && (original!==behavioral || original!==physical))
   $fatal(1,"menu byte/latency mismatch n=%0d original=%h behavioral=%h physical=%h",
       n,original,behavioral,physical);
 end
 $display("PASS 131072 menu decode byte/latency comparisons against frozen original; native+behavioral, all banks/pages/modes/rows/columns, X/Z fallback");
 $finish;
end
initial begin #2000000;$fatal(1,"menu equivalence watchdog");end
endmodule
''', encoding='utf-8')
    simulate(work / 'simulation', 'tb_menu_decode',
             [old_file, board / relative, hardware, tb],
             includes=[board / 'rtl/ui'], defines=['DB_BEHAVIORAL_RAM'], native=True)


if __name__ == '__main__':
    main()
