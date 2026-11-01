"""Exercise the actual TX descriptor lifetime with delayed MAC acceptance.

Existing link oracle checks every received payload word, metadata, retry bounds,
CRC recovery and sequence wrap. Additional assertions watch the full mailbox
while the MAC owns it. Runs behavioral and native synchronous RAM models.
"""
import argparse
from pathlib import Path
from resource_sim import simulate

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--design-root', type=Path, required=True)
p.add_argument('--sequence-dsp',action='store_true',help='Seed public sequence wires until their first real capture for the 32-bit wrap oracle')
p.add_argument('--tag',default='tx-lifetime-equivalence')
args = p.parse_args()
root = args.design_root.resolve()
for board in ('media', 'render'):
    b = root / board
    work = root / args.tag / board
    work.mkdir(parents=True, exist_ok=True)
    s = (b / 'sim/tb_link.v').read_text(encoding='utf-8-sig')
    if args.sequence_dsp:
        seed="a.next_seq[2]=32'hfffffff8;b.expect_seq[2]=32'hfffffff8;"
        assert seed in s
        s=s.replace(seed,"force a.next_seq[2]=32'hfffffff8;force b.expect_seq[2]=32'hfffffff8;seed_tx=1;seed_rx=1;")
        marker='    initial begin #10000000;'
        control="""
    always @(posedge clk)begin
      if(seed_tx && a.tx_meta_valid && a.tx_meta_ready && a.tx_channel==2)begin
        #1;release a.next_seq[2];seed_tx=0;
      end
      if(seed_rx && b.receive_advance && !b.session_reset && b.delivery_ch==2)begin
        #1;release b.expect_seq[2];seed_rx=0;
      end
    end
"""
        s=s.replace('module tb_link;', 'module tb_link;\n    reg seed_tx=0,seed_rx=0;')
        s=s.replace(marker,control+marker)
    s = s.replace('    assign ack=valid && !active;', '''    reg [3:0] first_wait=0;
    always @(posedge clk or posedge rst)
        if(rst) first_wait<=0;
        else if(!valid || active) first_wait<=0;
        else if(first_wait!=9) first_wait<=first_wait+1'b1;
    assign ack=valid && !active && first_wait==9;''')
    s = s.replace('            if(valid) begin', '            if(valid && (active || ack)) begin')
    assertion = '''
    reg [255:0] held_mailbox_a,held_mailbox_b;
    reg held_busy_a=0,held_busy_b=0;
    always @(posedge clk) begin
        #1;
        if(!rst) begin
            if(held_busy_a && a.mac_busy && held_mailbox_a!==a.send_header)
                fail("TX A mailbox changed during MAC ownership");
            if(held_busy_b && b.mac_busy && held_mailbox_b!==b.send_header)
                fail("TX B mailbox changed during MAC ownership");
        end
        held_mailbox_a=a.send_header;held_mailbox_b=b.send_header;
        held_busy_a=!rst && a.mac_busy;held_busy_b=!rst && b.mac_busy;
    end
'''
    index = s.index('    initial begin #10000000;')
    s = s[:index] + assertion + s[index:]
    tb = work / 'tb_link_delayed.v'
    tb.write_text(s, encoding='utf-8')
    files = [b/'rtl/link'/f'{n}.v' for n in ('db_packet_ram','db_async_fifo','db_mac_rx','db_link')]+[tb]
    for native in (False, True):
        simulate(work/('native' if native else 'behavioral'), 'tb_link', files,
                 includes=[b/'rtl',b/'rtl/link'], native=native,
                 defines=[] if native else ['DB_BEHAVIORAL_RAM'])
