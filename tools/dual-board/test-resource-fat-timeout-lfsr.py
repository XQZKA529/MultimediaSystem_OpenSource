"""Prove sequence order and compare exact timeout flags to binary counters.

Independent matrix exponentiation validates polynomial arithmetic certificates.
Boundary state injection covers production 100M-cycle and 31-bit limits without
skipping the proof of absent earlier aliases. Real FAT timeout tests are separate.
"""
import argparse,json,random
from pathlib import Path
from resource_lfsr import factors,power_x
from resource_sim import simulate

def matrix_power(exponent,bits,polynomial):
    mask=(1<<bits)-1
    def step(value):return ((value<<1)&mask) ^ (polynomial if value>>(bits-1) else 0)
    matrix=[step(1<<i) for i in range(bits)]
    def apply(columns,value):
        result=0
        for i,column in enumerate(columns):
            if value>>i&1:result^=column
        return result
    state=1
    while exponent:
        if exponent&1:state=apply(matrix,state)
        matrix=[apply(matrix,column) for column in matrix];exponent>>=1
    return state

p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
a=p.parse_args();b=a.candidate.resolve();proof=b.parent/'timeout-lfsr-proof'
certificates=json.loads((proof/'period-certificates.json').read_text())
for item in certificates:
    bits=item['bits'];poly=item['polynomial'];period=(1<<bits)-1
    assert item['period']==period and item['prime_divisors']==factors(period)
    assert power_x(period,bits,poly)==matrix_power(period,bits,poly)==1
    for prime in factors(period):
        value=matrix_power(period//prime,bits,poly)
        assert value==power_x(period//prime,bits,poly)==item['proper_divisor_powers'][str(prime)] and value!=1
prefix=(proof/'timer-logic.vh').read_text()
assert prefix in (b/'rtl/fat/fat32_ro.v').read_text(encoding='utf-8-sig')
w=b.parent/'timeout-lfsr-equivalence';w.mkdir(parents=True,exist_ok=True)
tb='''module encoded #(parameter integer IO_TIMEOUT_CYCLES=100000000)(input wire clk,rst,clear,enable,output reg expired);
'''+prefix+'''
always @(posedge clk or posedge rst)begin
 if(rst)begin io_timeout<=IO_USE_LFSR ? 1:0;expired<=0;end
 else if(clear)begin io_timeout<=IO_USE_LFSR ? 1:0;expired<=0;end
 else if(enable && !expired)begin io_timeout<=io_advance;expired<=io_predicate;end
end endmodule
module binary #(parameter integer IO_TIMEOUT_CYCLES=100000000)(input wire clk,rst,clear,enable,output reg expired);
reg [$clog2(IO_TIMEOUT_CYCLES+1)-1:0] count;
always @(posedge clk or posedge rst)begin
 if(rst)begin count<=0;expired<=0;end
 else if(clear)begin count<=0;expired<=0;end
 else if(enable && !expired)begin count<=count+28'd1;expired<=(count+28'd1>=IO_TIMEOUT_CYCLES-1);end
end endmodule
module tb;
reg clk=0,rst=1,clear=0,enable=0;always #5 clk=~clk;
integer n,checks=0;reg [31:0] rng=32'h710fab32;
'''
limits=[0,1,2,3,4,7,8,63,64,512,1000,100000000,2147483647]
for i,limit in enumerate(limits):
    tb+=f'''wire actual{i},expected{i};
encoded #(.IO_TIMEOUT_CYCLES({limit})) dut{i}(clk,rst,clear,enable,actual{i});
binary #(.IO_TIMEOUT_CYCLES({limit})) golden{i}(clk,rst,clear,enable,expected{i});
always @(posedge clk)begin #1;if(actual{i}!==expected{i})$fatal(1,"Timeout deadline mismatch limit={limit} cycle %d",checks);end
'''
tb+='''always @(posedge clk)checks=checks+1;
initial begin repeat(5)@(negedge clk);rst=0;
for(n=0;n<160000;n=n+1)begin
 rng=rng*32'd1664525+32'd1013904223;enable=rng[4];clear=n%97==0 || n%1009<3;
 if(n%2017==13)begin rst=1;#2;rst=0;end
 @(negedge clk);
end
clear=0;enable=1;
'''
by_bits={item['bits']:item for item in certificates};random_source=random.Random(193005)
injections=0
for i,limit in enumerate(limits):
    if limit<3:continue
    bits=limit.bit_length();poly=by_bits[bits]['polynomial']
    counts=sorted({0,1,max(0,limit-3),limit-2,limit-1,*[random_source.randrange(limit) for _ in range(100)]})
    for count in counts:
        encoded=matrix_power(count,bits,poly);last=int(count>=limit-1)
        tb+=f'''@(negedge clk);dut{i}.io_timeout={bits}'h{encoded:x};golden{i}.count={count};
dut{i}.expired=1'b{last};golden{i}.expired=1'b{last};repeat(4)@(negedge clk);
'''
        injections+=1
tb+=f'''$display("PASS 31 independently matrix-verified maximal-period certificates; 13 binary timeout parameter cases including 0/1/2 fallback; {injections} production/boundary injections and %d exact enabled/clear/reset flag cycles; no earlier deadline aliases",checks);$finish;
end endmodule
'''
f=w/'tb.v';f.write_text(tb,encoding='utf-8')
simulate(w/'simulation','tb',[f])
(proof/'matrix-verification.json').write_text(json.dumps(dict(status='PASS',widths=list(range(2,33)),limits=limits,
 boundary_injections=injections,method='Independent GF(2) transition-matrix exponentiation and prime-divisor period proof'),indent=2),encoding='utf-8')
