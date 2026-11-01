"""An isolated encoding candidate for the 16-state file browser controller.

Preserves every branch, priority, return state and external diagnostic number.
Other controllers retain their existing encoding.
"""
import argparse
from pathlib import Path
import re
from resource_experiment import snapshot

p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
args=p.parse_args()
snapshot(args.source,args.destination)
file=args.destination/'rtl/ui/file_browser.v'
s=file.read_text(encoding='utf-8-sig')
a=s.index('    reg [15:0] state_hot;');b=s.index('    reg        dir_own_r;',a)
s=s[:a]+'''    reg [3:0] state_encoded;
    wire [3:0] state=state_encoded;
'''+s[b:]
s=s.replace('reg [15:0] draw_return_hot;', 'reg [3:0] draw_return_encoded;')
s=re.sub(r"\(?16'b1\s*<<\s*(S_\w+)\)?",r'\1',s)
s=re.sub(r'state_hot\[(S_\w+)\](\s*:)',r'\1\2',s)
s=re.sub(r'state_hot\[(S_\w+)\]',r'(state_encoded==\1)',s)
s=s.replace("case(1'b1)",'case(state_encoded)').replace("case (1'b1)",'case (state_encoded)')
s=s.replace('draw_return_hot','draw_return_encoded').replace('state_hot','state_encoded')
assert "16'b1" not in s
file.write_text(s,encoding='utf-8')
# The existing oracle asserts the implementation's encoding in addition to its
# functional checks. Replace just that invariant; all transaction checks stay.
test=args.destination/'sim/tb_settings_menu.v'
s=test.read_text(encoding='utf-8-sig')
s=s.replace('dut.state_hot==0 || (dut.state_hot & (dut.state_hot-1))!=0',
            "(dut.state_encoded ^ dut.state_encoded)!==4'd0")
s=s.replace('Browser control state must remain one-hot','Browser control state must remain defined')
s=s.replace('dut.state_hot','dut.state_encoded')
s=s.replace('!dut.state_encoded[state]', 'dut.state_encoded!==state')
test.write_text(s,encoding='utf-8')
