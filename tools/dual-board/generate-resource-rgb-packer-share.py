"""Share the mutually exclusive RGB888 packer's three carry lifetimes.

All phases receive the same B byte in bits 7:0; phases 0/1 receive G in
15:8; only phase 0 needs R in 23:16. One 24-bit bank therefore replaces
24+16+8 bits without adding muxes, changing output cycles or RGB precision.
"""
import argparse
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--unreset-carry',action='store_true',help='Remove private carry reset; phase zero overwrites all bits before any output word')
p.add_argument('--eager-carry',action='store_true',help='Capture private carry even while reset/start/overflow suppress publication')
a=p.parse_args();assert not a.eager_carry or a.unreset_carry;snapshot(a.source,a.destination)
f=a.destination/'rtl/framebuffer/rgb888_word_packer.v';s=f.read_text(encoding='utf-8-sig')
old='''    reg [23:0] pixel0;
    reg [15:0] carry16;
    reg [7:0]  carry8;'''
assert s.count(old)==1
s=s.replace(old,'    reg [23:0] carry;')
old='''            pixel0          <= 24'd0;
            carry16         <= 16'd0;
            carry8          <= 8'd0;'''
assert s.count(old)==1;s=s.replace(old,"            carry           <= 24'd0;")
pairs=[('pixel0 <= pixel_rgb;','carry <= pixel_rgb;'),
       ('{pixel0, pixel_rgb[23:16]}','{carry, pixel_rgb[23:16]}'),
       ('carry16    <= pixel_rgb[15:0];','carry[15:0] <= pixel_rgb[15:0];'),
       ('{carry16, pixel_rgb[23:8]}','{carry[15:0], pixel_rgb[23:8]}'),
       ('carry8     <= pixel_rgb[7:0];','carry[7:0] <= pixel_rgb[7:0];'),
       ('{carry8, pixel_rgb}','{carry[7:0], pixel_rgb}')]
for old,new in pairs:
 assert s.count(old)==1,old;s=s.replace(old,new)
if a.unreset_carry:
 for old in ("carry           <= 24'd0;",'carry <= pixel_rgb;',
             'carry[15:0] <= pixel_rgb[15:0];','carry[7:0] <= pixel_rgb[7:0];'):
  assert s.count(old)==1;s=s.replace(old,'')
 marker='    always @(posedge clk or posedge rst) begin'
 assert s.count(marker)==1
 capture='''    // Phase zero captures the complete private carry before phase one
    // can publish a word. Reset/start always restore phase zero; public
    // word_data, valid and all error/counter state retain their reset values.
    always @(posedge clk)begin
        if(!rst && !frame_start && pixel_valid && !(pixel_count>=FRAME_PIXELS))begin
            case(phase)
                2'd0:carry<=pixel_rgb;
                2'd1:carry[15:0]<=pixel_rgb[15:0];
                2'd2:carry[7:0]<=pixel_rgb[7:0];
                default:;
            endcase
        end
    end
'''
 s=s.replace(marker,capture+marker)
 if a.eager_carry:
  s=s.replace('if(!rst && !frame_start && pixel_valid && !(pixel_count>=FRAME_PIXELS))begin',
              'if(pixel_valid)begin')
  s=s.replace('    // Phase zero captures the complete private carry before phase one',
'''    // Extra private captures during reset/start/overflow are unobservable:
    // leaving any such condition first restores phase zero, which overwrites
    // all 24 bits before a word can publish. No public guard is relaxed.
    // Phase zero captures the complete private carry before phase one''')
f.write_text(s,encoding='utf-8')
