"""Mirror all calendar outputs and every combinational draft edit."""
import argparse
from pathlib import Path
from resource_sim import simulate
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--reference',type=Path,required=True);p.add_argument('--tag',default='calendar-shared-equivalence');a=p.parse_args();b=a.candidate.resolve();r=a.reference.resolve()
w=b.parent/a.tag;w.mkdir(parents=True,exist_ok=True)
ref=w/'reference.v';ref.write_text((r/'rtl/ui/calendar_clock.v').read_text(encoding='utf-8-sig').replace('module calendar_clock #(', 'module reference_calendar #('),encoding='utf-8')
tb=w/'tb.v';tb.write_text('''module tb;
reg clk=0,rst=1,enable=0,cancel=0,up=0,down=0,left=0,right=0,confirm=0;
always #5 clk=~clk;
wire [275:0] actual,expected;
genvar g;generate for(g=0;g<4;g=g+1)begin: calendar
 localparam HZ=g==0 ? 1:g==1 ? 2:g==2 ? 7:113;
 wire editing_a,editing_e;
 calendar_clock #(.CLK_HZ(HZ)) u(clk,rst,enable,cancel,up,down,left,right,confirm,
   actual[g*69+:33],actual[g*69+33+:33],actual[g*69+66+:3],editing_a);
 reference_calendar #(.CLK_HZ(HZ)) v(clk,rst,enable,cancel,up,down,left,right,confirm,
   expected[g*69+:33],expected[g*69+33+:33],expected[g*69+66+:3],editing_e);
 wire [32:0] adjusted_a=u.adjusted,adjusted_e=v.adjusted;
 wire [32:0] draft_a=u.draft;wire [2:0] focus_a=u.focus;
 always @(posedge clk)begin #1;
  if(actual[g*69+:69]!==expected[g*69+:69] || editing_a!==editing_e)
   $fatal(1,"calendar public output mismatch HZ=%d",HZ);
  if(adjusted_a!==adjusted_e)$fatal(1,"calendar field edit mismatch HZ=%d focus=%d draft=%h",HZ,focus_a,draft_a);
 end
end endgenerate
integer n,f,direction,checks=0;reg [32:0] value;
wire [32:0] check_adjusted_a=calendar[0].u.adjusted,check_adjusted_e=calendar[0].v.adjusted;
initial begin
repeat(5)@(negedge clk);rst=0;
for(n=0;n<300000;n=n+1)begin
 {enable,cancel,up,down,left,right,confirm}=$random;
 if(n%5000==0)begin rst=1;#2;rst=0;end
 @(negedge clk);checks=checks+1;
end
// All encoded values of each individual field, both directions and every
// focus, including illegal month/day/time values and leap-year boundaries.
enable=0;cancel=0;up=0;down=0;left=0;confirm=0;
for(n=0;n<200000;n=n+1)begin
 value={$random,$random};
 if(n<16384)value={n[13:7],n[6:3],n[2:0],2'b01,5'd23,6'd59,6'd59};
 for(f=0;f<8;f=f+1)for(direction=0;direction<2;direction=direction+1)begin
  calendar[0].u.draft=value;calendar[0].v.draft=value;
  calendar[0].u.focus=f;calendar[0].v.focus=f;right=direction;
  #1;if(check_adjusted_a!==check_adjusted_e)$fatal(1,"exhaustive draft edit differs value=%h focus=%d",value,f);
  checks=checks+1;
 end
 @(negedge clk);
end
$display("PASS %d calendar public/edit checks at HZ=1/2/7/113, concurrent tick/edit/apply/cancel, all focus/directions, invalid encoded fields and random 33-bit dates",checks);$finish;
end endmodule
''',encoding='utf-8')
simulate(w/'behavioral','tb',[ref,b/'rtl/ui/calendar_clock.v',tb])
