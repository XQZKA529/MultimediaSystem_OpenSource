"""Run FAT transaction oracles with the actual embedded context RAM model."""
import argparse
from pathlib import Path
from resource_sim import simulate

p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True)
args=p.parse_args();b=args.candidate.resolve()
for test in ('tb_fat32_ro','tb_fat32_directory','tb_fat32_map','tb_fat32_timeout'):
    simulate(b.parent/'fat-context-native'/test,test,[b/'rtl/fat/fat32_ro.v',b/'sim'/f'{test}.v'],
             includes=[b/'rtl',b/'rtl/pkg'],native=True)
