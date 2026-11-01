"""Compare every shared-font address on both native and behavioral RAM ports."""
import argparse
from pathlib import Path
from resource_sim import simulate

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root', type=Path, required=True)
p.add_argument('--reference-root', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
b = a.source_root.resolve()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
reference = out / 'reference_font.v'
s = (a.reference_root / 'rtl/ui/font_rom.v').read_text(encoding='utf-8')
s = s.replace('module font_rom #(', 'module reference_font #(')
s = s.replace('resource_font_middle', 'reference_font_middle')
reference.write_text(s, encoding='utf-8')
tb = out / 'tb.v'
tb.write_text('''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg [6:0] ca=0,cb=0;reg [3:0] xa=0,xb=0,ya=0,yb=0;
wire [1:0] aa,ab,ea,eb;integer n,checks=0;
font_rom #(.SECOND_PORT(1)) f(clk,ca,xa,ya,aa,cb,xb,yb,ab);
reference_font #(.SECOND_PORT(1)) rf(clk,ca,xa,ya,ea,cb,xb,yb,eb);
always @(posedge clk)begin #1;
 if({aa,ab}!=={ea,eb})$fatal(1,"glyph mismatch %d a=%h/%h b=%h/%h",checks,aa,ea,ab,eb);
 checks=checks+1;
end
initial begin
 for(n=0;n<32768;n=n+1)begin
  @(negedge clk);ca=n[14:8];ya=n[7:4];xa=n[3:0];
  cb=~ca;yb=~ya;xb=~xa;
 end
 for(n=0;n<100000;n=n+1)begin
  @(negedge clk);ca=$random;cb=$random;xa=$random;xb=$random;ya=$random;yb=$random;
 end
 repeat(3)@(negedge clk);
 $display("PASS %d exact two-port glyph cycles; full 128x16x16 addresses and random independent reads",checks);$finish;
end
endmodule
''', encoding='utf-8')
for native in (False, True):
    simulate(out / ('native' if native else 'behavioral'), 'tb',
             [reference, b / 'rtl/ui/font_rom.v', tb],
             defines=[] if native else ['DB_BEHAVIORAL_RAM'], native=native)
