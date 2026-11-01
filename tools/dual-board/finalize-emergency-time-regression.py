"""Reuse a completed suite only when its sole subsequent RTL delta is local CDC.

Both tests that compile that module must have freshly checked simulation input
manifests. Media/system suites never compile it; all their production inputs
are proved byte-identical. Frame simulations bind their own input manifests.
This is dependency-scoped evidence reuse, not a waiver of bit/source gates.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
WORK=ROOT/'build/emergency-time-v1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inputs(board):
    root=ROOT/board;data={}
    for folder in ('rtl','al_ip','constr'):
        for p in (root/folder).rglob('*'):
            if p.is_file():data[p.relative_to(root).as_posix()]=sha(p)
    for p in (root/'build').iterdir():
        if p.is_file() and (p.suffix in ('.ps1','.tcl') or p.name=='sources.txt'):data[p.relative_to(root).as_posix()]=sha(p)
    return data

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--base-render',required=True)
    parser.add_argument('--completed-console',type=Path,required=True);args=parser.parse_args()
    baseline=json.loads((ROOT/'render/Runs'/('syn_'+args.base_render)/'inputs.json').read_text())
    current={board:inputs(board) for board in ('media','render')}
    delta={p for p in set(baseline)|set(current['render']) if baseline.get(p)!=current['render'].get(p)}
    if delta!={'rtl/emergency/emergency_view_cdc.v'}:raise SystemExit('Unsafe suite reuse; unexpected production delta: '+repr(delta))
    media_base=json.loads((ROOT/'media/Runs/phy_clock_v1_medium3/inputs.json').read_text())
    if current['media']!=media_base:raise SystemExit('Media inputs changed')
    text=args.completed_console.read_text(encoding='utf-8-sig',errors='replace')
    if '691200 RGB888 packed words' not in text or 'PASS: baseline hashes unchanged' not in text:raise SystemExit('Suite did not finish full-image and audit checks')
    for path in ('media/sim/run.ps1','tools/dual-board/run-system.ps1'):
        if 'emergency_view_cdc' in (ROOT/path).read_text(encoding='utf-8'):raise SystemExit('CDC now participates in cached media/system suites')
    names=['tb_emergency_timestamp','tb_emergency_controller','tb_calendar_clock','tb_clock_view_cdc','tb_clock_events','tb_audio_volume_gain','tb_mix_transition']
    names += ['media_'+n for n in ('tb_emergency_media','tb_keypad_images','tb_emergency_integration','tb_emergency_integration_mono')]
    names += ['media_tb_emergency_integration_'+n for n in ('gpio','quick','paused','format','missing','read_error','reentry','empty','disconnect','reset','render_reset','switch','paused_switch','restore_body_error','switch_many','pending_begin','cfg_race')]
    names += ['emergency-system']
    names += ['media_'+n for n in ('tb_link','tb_temac_gate','tb_fat_wav_controller','tb_fat_wav_actual','tb_media_sd_boot','tb_settings_menu','tb_bmp_controller','tb_keypad_router','tb_volume_transport','tb_sd_subtitle_controller','tb_sd_subtitle_fat','tb_fat_wav_controller_external_position','tb_settings_menu_shared')]
    names += ['tb_link','tb_temac_gate','tb_audio_sink','tb_image_commit','tb_ui_snapshot','tb_text_osd_events','tb_sd_subtitle_view','tb_volume_protocol','tb_frame_read_dual']
    names += ['text-osd-menu-system','audio-system-0-mono0_bmp_scale','audio-system-0-mono1_bmp_scale','sd-subtitle-system_no_frames','system-691200_bmp_scale_720p']
    assert len(names)==56 and len(set(names))==56
    evidence={}
    for name in names:
        p=WORK/'evidence'/(name+'.txt')
        if '*** PASS ***' not in p.read_text(encoding='utf-8'):raise SystemExit('Missing PASS '+name)
        evidence[p.name]=sha(p)
    for name in ('tb_emergency_timestamp','tb_emergency_controller'):
        dependency=json.loads((WORK/'evidence'/(name+'.inputs.json')).read_text(encoding='utf-8'))
        target=ROOT/'render/rtl/emergency/emergency_view_cdc.v'
        if dependency.get(str(target))!=sha(target):raise SystemExit('Must rerun affected '+name)
        for path,digest in dependency.items():
            if sha(Path(path))!=digest:raise SystemExit('Changed affected simulation dependency: '+path)
    # Other recorded render dependencies must also match before reusing them.
    for p in (WORK/'evidence').glob('*.inputs.json'):
        for path,digest in json.loads(p.read_text(encoding='utf-8')).items():
            if sha(Path(path))!=digest:raise SystemExit('Changed cached simulation dependency: '+path)
    proof={'base_render_run':args.base_render,'completed_console_sha256':sha(args.completed_console),
           'production_delta':sorted(delta),'rerun_affected_tests':['tb_emergency_timestamp','tb_emergency_controller'],
           'reused_unaffected_executions':54,'baseline_render_inputs':baseline,
           'media_system_compile_scripts':{p:sha(ROOT/p) for p in ('media/sim/run.ps1','tools/dual-board/run-system.ps1')}}
    data={'test_count':56,'frames_executed':False,'inputs':current,'evidence':evidence,
          'hardware_acceptance':'pending','dependency_scoped_reuse':proof}
    (WORK/'regression.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS 56 verified executions: 54 unchanged dependencies reused, 2 affected CDC tests rerun')
