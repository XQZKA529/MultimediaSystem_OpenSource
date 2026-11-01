"""Group one FAT controller's binary codes while preserving numeric diagnostics.

Only this FSM is recoded. Directory, file/FAT and map phases share high code
bits to expose their common decode terms. All 72 legal diagnostic state values
and transition/write edges remain exact; illegal codes still recover to IDLE.
"""
import argparse,re,json,collections
from pathlib import Path
from resource_experiment import snapshot
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--preserve-lowbits',action='store_true')
p.add_argument('--gray',action='store_true',help='Gray-code the existing five-bit local ordinal within each operation group')
a=p.parse_args();assert not(a.gray and a.preserve_lowbits);snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v';s=f.read_text(encoding='utf-8-sig')
original={name:int(value) for name,value in re.findall(r"\b(S_\w+)\s*=\s*8'd(\d+)",s)}
assert len(original)==72 and set(original.values())==set(range(72))
groups=collections.defaultdict(list)
for name,value in original.items():
 group=0 if name in ('S_IDLE','S_RD_REQ','S_RD_WAIT','S_FAIL') or name.startswith('S_MOUNT') else 1 if name.startswith(('S_DIR','S_LFN','S_SFN','S_EMIT','S_CSUM','S_BUILD')) else 2 if name.startswith(('S_FILE','S_FAT')) else 3 if name.startswith('S_MAP') else -1
 assert group>=0,name
 groups[group].append(name)
encoded={}
for group,names in groups.items():
 assert len(names)<=32
 for i,name in enumerate(sorted(names,key=original.get)):encoded[name]=group*32+(i^(i>>1) if a.gray else i)
if a.preserve_lowbits:
 # Almost every diagnostic code can keep its low five bits. Relocate only
 # the collisions within mount and directory groups, making inverse decode
 # simple wiring for all file/FAT and map phases.
 relocations={32:10,36:11,37:12,33:20,35:21,39:22}
 for group,names in groups.items():
  for name in names:encoded[name]=group*32+relocations.get(original[name],original[name]&31)
assert encoded['S_IDLE']==0 and len(set(encoded.values()))==72
for name,value in original.items():
 s,n=re.subn(r'(\b'+name+r"\s*=\s*8'd)"+str(value)+r'\b',lambda m:m[1]+str(encoded[name]),s)
 assert n==1,name
s=re.sub(r'\bstate_encoded\b','control_state',s)
old="wire [7:0] state={1'b0,control_state};";assert s.count(old)==1
decoder='''reg [7:0] state;
// Keep the legacy diagnostic alias used by debug ports and invariant benches.
wire [6:0] state_encoded=state[6:0];
always @* begin
 case(control_state)
'''
decoder+=''.join(f"  7'd{encoded[name]}:state=8'd{value};\n" for name,value in sorted(original.items(),key=lambda item:item[1]))
decoder+="  default:state=8'hff;\n endcase\nend"
if a.preserve_lowbits:
 decoder='''reg [7:0] state;
wire [6:0] state_encoded=state[6:0];
// Preserve the legacy numeric diagnostics without a 72-entry inverse mux.
always @* begin
 state=8'hff;
 case(control_state[6:5])
  2'b00:case(control_state[4:0])
   10:state=32;11:state=36;12:state=37;
   default:state={2'b00,(control_state[4] && control_state[4:0]!=5'd29),control_state[4:0]};
  endcase
  2'b01:case(control_state[4:0])
   20:state=33;21:state=35;22:state=39;
   default:state={1'b0,(control_state[4:0]<8),
     (control_state[4:0]==8 || control_state[4:0]>=28),control_state[4:0]};
  endcase
  2'b10:state={2'b00,!control_state[4],control_state[4:0]};
  2'b11:state={3'b001,control_state[4:0]};
  default:state=8'hff;
 endcase
end'''
s=s.replace(old,decoder)
f.write_text(s,encoding='utf-8')
(a.destination.parent/'fat-control-map.json').write_text(json.dumps({name:dict(diagnostic=original[name],encoded=encoded[name]) for name in original},indent=2),encoding='utf-8')
