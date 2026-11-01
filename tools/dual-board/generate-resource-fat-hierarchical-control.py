"""Factor the grouped FAT FSM's case selection without changing any edge.

The existing group bits select four independent five-bit case decoders.
All 71 implemented bodies, their order within a group, and recovery stay exact.
The legacy MBR_CHK diagnostic constant already has no body and keeps default.
"""
import argparse, collections, json, re, shutil
from pathlib import Path
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args()
snapshot(a.source,a.destination)
f=a.destination/'rtl/fat/fat32_ro.v'
s=f.read_text(encoding='utf-8-sig')
codes={name:int(value) for name,value in re.findall(r"\b(S_\w+)\s*=\s*8'd(\d+)",s)}
starts=list(re.finditer(r'^    case\s*\(control_state\)',s,re.M))
assert len(starts)==1
start=starts[0].start()
closing=re.search(r'^    endcase\s*$',s[start:],re.M)
assert closing
end=start+closing.end()
body=s[start:end]
labels=list(re.finditer(r'^      (S_\w+)\s*:',body,re.M))
assert len(labels)==71 and set(codes)-{label[1] for label in labels}=={'S_MOUNT_MBR_CHK'}
default=body.index('      default: control_state<=S_IDLE;')
groups=collections.defaultdict(list)
for i,label in enumerate(labels):
    name=label[1]
    block=body[label.start():labels[i+1].start() if i+1<len(labels) else default]
    block=re.sub(r'^      '+name+r'\s*:',f"      5'd{codes[name]&31}:",block,count=1)
    groups[codes[name]>>5].append(block)
replacement='    case(control_state[6:5])\n'
for group,blocks in sorted(groups.items()):
    replacement+=f"      2'd{group}:begin\n        case(control_state[4:0])\n"
    replacement+=''.join(blocks)
    replacement+='      default:control_state<=S_IDLE;\n        endcase\n      end\n'
replacement+='      default:control_state<=S_IDLE;\n    endcase'
f.write_text(s[:start]+replacement+s[end:],encoding='utf-8')
shutil.copy2(a.source.parent/'fat-control-map.json',a.destination.parent/'fat-control-map.json')
(a.destination.parent/'hierarchical-control.json').write_text(json.dumps(
    dict(states=len(labels),group_sizes={k:len(v) for k,v in groups.items()},
         changed_latency=False,changed_encoding=False),indent=2),encoding='utf-8')
