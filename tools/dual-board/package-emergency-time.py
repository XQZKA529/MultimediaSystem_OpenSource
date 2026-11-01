"""Package only fingerprint-matched, legal-resource, zero-hold timestamp trials."""
import argparse
import hashlib
import importlib.util
import json
import shutil
import zipfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
WORK=ROOT/'build/emergency-time-v1'
PARENT=ROOT/'build/clock-rx-timing-fix/release_clock_rx_timing_trial'
spec=importlib.util.spec_from_file_location('clock_reports',Path(__file__).with_name('clock-build-report.py'))
reports=importlib.util.module_from_spec(spec);spec.loader.exec_module(reports)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def copy(p,q):q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
def check_inputs(mapping,base):
    for name,value in mapping.items():
        p=base/name
        if not p.is_file() or sha(p)!=value:raise SystemExit('Changed/missing input or evidence: '+str(p))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--render',required=True)
    parser.add_argument('--name',default='release_emergency_time_trial');args=parser.parse_args()
    if Path(args.name).name!=args.name:raise SystemExit('Release name must be a directory name')
    out=WORK/args.name
    if out.exists():raise SystemExit('Release exists; preserve it and choose --name')
    old=json.loads((PARENT/'manifest.json').read_text(encoding='utf-8'))
    suite=json.loads((WORK/'regression.json').read_text(encoding='utf-8'))
    visual=json.loads((WORK/'visual-check.json').read_text(encoding='utf-8'))
    if (suite['test_count'],suite['frames_executed']) not in ((56,False),(58,True)):raise SystemExit('Requires the complete 56-test suite plus two frame simulations')
    if not visual['pass'] or len(visual['alarm_frames'])!=25 or len(visual['clock_frames'])!=11:raise SystemExit('Missing complete visual validation')
    check_inputs(suite['evidence'],WORK/'evidence');check_inputs(visual['inputs'],ROOT);check_inputs(visual['evidence'],WORK)
    evidence=dict(suite['evidence'])
    for name in ('tb_emergency_overlay','tb_clock_overlay'):
        p=WORK/'evidence'/f'{name}.txt'
        if '*** PASS ***' not in p.read_text(encoding='utf-8'):raise SystemExit('Missing frame simulation PASS')
        inputs=json.loads((WORK/'evidence'/f'{name}.inputs.json').read_text(encoding='utf-8'))
        check_inputs(inputs,ROOT)  # absolute simulator dependencies are checked too
        evidence[p.name]=sha(p)
    # Validate every recorded simulator input, not only the design-wide manifest.
    for p in (WORK/'evidence').glob('*.inputs.json'):
        check_inputs(json.loads(p.read_text(encoding='utf-8')),ROOT)
    boards={'media':reports.board_report('media','clock_v1_medium3'),
            'render':reports.board_report('render',args.render)}
    for board,data in boards.items():
        if data['inputs']!=suite['inputs'][board]:raise SystemExit(board+': regression/build fingerprints differ')
        if not data['trial_timing_eligible'] or any(data['hard_block_delta'].values()):raise SystemExit(board+': illegal resources, hold violations or new hard blocks')
    if boards['media']['inputs']!=old['boards']['media']['inputs']:raise SystemExit('Media production inputs changed')
    delta=[name for name,value in boards['render']['inputs'].items() if old['boards']['render']['inputs'].get(name)!=value]
    allowed={'rtl/emergency/emergency_inputs.v','rtl/emergency/emergency_view_cdc.v','rtl/emergency/emergency_overlay.v','rtl/top_render.v','rtl/render_core.v'}
    if set(delta)!=allowed:raise SystemExit('Unexpected render production delta: '+repr(delta))
    media_bit=PARENT/'media_CLOCK_RX_TIMING_TRIAL.bit'
    if sha(media_bit)!=old['boards']['media']['bit_sha256']:raise SystemExit('Paired media bit changed')
    run=ROOT/'render/Runs'/('phy_'+args.render)
    render_bit=run/'MultimediaSystem_render_EMERGENCY_TIME_TRIAL.bit'
    if not render_bit.is_file():raise SystemExit('Missing authorized timestamp trial bit')
    out.mkdir()
    shutil.copytree(PARENT/'source',out/'source')
    # Refresh all production inputs, retaining the parent's original baseline/IP.
    for board,data in boards.items():
        for name,value in data['inputs'].items():
            copy(ROOT/board/name,out/'source'/board/name)
            if sha(out/'source'/board/name)!=value:raise SystemExit('Source copy mismatch')
        for folder in ('sim','doc'):
            for p in (ROOT/board/folder).rglob('*'):
                if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.pyc','.ppm','.png'):
                    copy(p,out/'source'/board/folder/p.relative_to(ROOT/board/folder))
    for name in ('README.md','README-dual-board.md','render/README.md','media/README.md',
                 'render/MultimediaSystem_render.al','media/MultimediaSystem_media.al',
                 'doc/dual-board/emergency-time-2026-10-14.md'):
        copy(ROOT/name,out/'source'/name)
    for p in (ROOT/'tools/dual-board').glob('*'):
        if p.is_file() and p.suffix in ('.py','.ps1','.v','.vh','.tcl'):copy(p,out/'source/tools/dual-board'/p.name)
    for p in run.iterdir():
        if p.is_file() and (p.suffix in ('.timing','.ts','.area','.qor','.cfg','.json') or p.name in ('console.txt','emergency-time-trial-bitgen.txt','generate-emergency-time-trial.tcl')):
            copy(p,out/'reports/render'/p.name)
    for p in (PARENT/'reports/media').glob('*'):
        if p.is_file():copy(p,out/'reports/media'/p.name)
    # Preserve failed capacity attempts as evidence, without counting them as PASS.
    candidates={}
    for candidate in sorted((ROOT/'render/Runs').glob('phy_emergency_time_*')):
        tag=candidate.name[4:]
        if tag==args.render:continue
        if (candidate/'console.txt').exists():
            content=(candidate/'console.txt').read_text(encoding='utf-8',errors='replace')
            candidates[tag]={'capacity_failed':'PHY-9009 ERROR' in content,'tool_crashed':'coredump' in content,'console_sha256':sha(candidate/'console.txt')}
            for name in ('console.txt','inputs.json','settings.cfg'):
                if (candidate/name).exists():copy(candidate/name,out/'evidence/candidates'/tag/name)
    (out/'evidence/candidates.json').write_text(json.dumps(candidates,indent=2)+'\n',encoding='utf-8')
    copy(media_bit,out/'media_CLOCK_RX_TIMING_TRIAL.bit');copy(render_bit,out/'render_EMERGENCY_TIME_TRIAL.bit')
    for p in (WORK/'evidence').iterdir():
        if p.is_file():copy(p,out/'evidence'/p.name)
    shutil.copytree(WORK/'preview',out/'preview')
    copy(WORK/'visual-check.json',out/'visual-check.json')
    console=WORK/'regression-final-v6-console.txt'
    if not console.exists():console=WORK/'regression-final-console.txt'
    if not console.exists():console=WORK/'regression-console.txt'
    if console.exists():copy(console,out/'regression-console.txt')
    merged={**suite,'test_count':len(evidence),'frames_executed':True,'evidence':evidence}
    (out/'regression.json').write_text(json.dumps(merged,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    for board,data in boards.items():
        bit=out/('media_CLOCK_RX_TIMING_TRIAL.bit' if board=='media' else 'render_EMERGENCY_TIME_TRIAL.bit')
        data['bit_sha256']=sha(bit)
    baseline=old['boards']['render']
    boards['render']['parent_slice_delta']=boards['render']['slices']-baseline['slices']
    manifest={'artifact_type':'paired_emergency_timestamp_hardware_trial','protocol':'1.9','hardware_acceptance':'pending',
              'media_bit_reused':True,'parent_release':'clock-rx-timing-fix','test_count':len(evidence),
              'production_delta':['render/'+n for n in delta],'boards':boards,
              'evidence':{p.relative_to(out).as_posix():sha(p) for p in (out/'evidence').rglob('*') if p.is_file()},
              'source_files':{p.relative_to(out/'source').as_posix():sha(p) for p in (out/'source').rglob('*') if p.is_file()}}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    r=boards['render']
    (out/'README.md').write_text(
        '# 紧急触发时间试板包\n\n'
        'B0、B1、C 的有效顺序同时记录 CLOCK 年月日和时分秒；解除后移除，再触发更新时间。\n'
        '已有 CLOCK 1.9 配套版本时仅下载 render_EMERGENCY_TIME_TRIAL.bit；media bit 与当前接收修复版完全相同。\n'
        '从 GPIO 1.8 升级需两板配套下载。实板验收待执行；原发布包保留作回退。\n\n'
        f"render: {r['slices']}/9800 Slice ({r['slice_percent']}%), Setup WNS {r['SWNS']} ns / TNS {r['STNS']} ns, "
        f"Hold WNS {r['HWNS']} ns / TNS {r['HTNS']} ns. 新增 BRAM/DSP/PLL 均为 0。\n"
        f"通过 {len(evidence)} 次仿真与 25+11 张完整画面检查。正式签核通过：{r['timing_qualified']}；试板标准通过：{r['trial_timing_eligible']}。\n\n"
        '完整操作与实板清单见 source/doc/dual-board/emergency-time-2026-10-14.md；SHA256 和源文件指纹见 manifest.json。\n',encoding='utf-8')
    zpath=WORK/(args.name+'.zip')
    if zpath.exists():raise SystemExit('ZIP exists; preserve it')
    with zipfile.ZipFile(zpath,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(out.rglob('*')):
            if p.is_file():z.write(p,p.relative_to(out.parent))
    with zipfile.ZipFile(zpath) as z:
        if z.testzip():raise SystemExit('ZIP validation failed')
        for name in ('media_CLOCK_RX_TIMING_TRIAL.bit','render_EMERGENCY_TIME_TRIAL.bit'):
            if hashlib.sha256(z.read(args.name+'/'+name)).hexdigest()!=sha(out/name):raise SystemExit('ZIP bit mismatch')
    zpath.with_suffix('.zip.sha256').write_text(sha(zpath)+'  '+zpath.name+'\n',encoding='utf-8')
    print('PACKAGED',zpath,'tests',len(evidence),'render slices',r['slices'],'hold',r['HWNS'],'setup',r['SWNS'])
