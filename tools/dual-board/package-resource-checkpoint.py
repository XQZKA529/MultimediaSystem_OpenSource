"""Package exact measured inputs and experimental bits; never certify 90%."""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
from resource_experiment import report,snapshot

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--media-run',type=Path,required=True)
p.add_argument('--render-run',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
p.add_argument('--render-alternative-run',type=Path)
args=p.parse_args()
dest=args.destination.resolve()
if dest.exists():raise RuntimeError('Checkpoint destination must be new')
reports={}
for board,run in [('media',args.media_run.resolve()),('render',args.render_run.resolve())]:
    with contextlib.redirect_stdout(io.StringIO()):report(board,run)
    r=json.loads((run/'resource-experiment.json').read_text(encoding='utf-8'))
    if not r['experiment_pass'] or not r['bit_sha256']:raise RuntimeError(f'{board}: missing accepted bit')
    expected=json.loads((run/'inputs.json').read_text(encoding='utf-8-sig'))
    for name,digest in expected.items():
        path=ROOT/board/name
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise RuntimeError(f'Production differs from measured input: {board}/{name}')
    reports[board]=r
dest.mkdir(parents=True)
alternatives=[]
if args.render_alternative_run:
    alt=args.render_alternative_run.resolve()
    with contextlib.redirect_stdout(io.StringIO()):report('render',alt)
    r=json.loads((alt/'resource-experiment.json').read_text(encoding='utf-8'))
    if not r['experiment_pass'] or not r['formal_timing_pass'] or not r['bit_sha256']:
        raise RuntimeError('Alternative requires accepted, timing-closed experimental bit')
    alt_inputs=json.loads((alt/'inputs.json').read_text(encoding='utf-8-sig'))
    primary_inputs=json.loads((args.render_run/'inputs.json').read_text(encoding='utf-8-sig'))
    source_prefix='source/render'
    if alt_inputs!=primary_inputs:
        # A timing/area alternative may retain a different measured RTL. Carry
        # its complete source rather than silently pairing it with the default.
        source_prefix='source-alternatives/render_timing_closed/render'
        origin=alt.parents[1]
        target=dest/source_prefix
        for folder in ('rtl','al_ip','constr','build','sim'):
            shutil.copytree(origin/folder,target/folder,ignore=shutil.ignore_patterns('evidence','__pycache__'))
        for al in origin.glob('*.al'):shutil.copy2(al,target/al.name)
        for name,digest in alt_inputs.items():
            if hashlib.sha256((target/name).read_bytes()).hexdigest()!=digest:
                raise RuntimeError(f'Alternative source changed: {name}')
    folder=dest/'alternatives/render_timing_closed';folder.mkdir(parents=True)
    bit=alt/'MultimediaSystem_render_RESOURCE_TRIAL.bit';shutil.copy2(bit,folder/bit.name)
    for name in ('resource-experiment.json','inputs.json','settings.cfg','final.qor','MultimediaSystem_render_phy.area','MultimediaSystem_render_phy.ts','MultimediaSystem_render_pr.timing'):
        shutil.copy2(alt/name,folder/name)
    alternatives.append(dict(board='render',file='alternatives/render_timing_closed/'+bit.name,
                             source_prefix=source_prefix,report=r))
for board,run in [('media',args.media_run.resolve()),('render',args.render_run.resolve())]:
    source=dest/'source'/board
    for folder in ('rtl','al_ip','constr','build','sim'):
        shutil.copytree(ROOT/board/folder,source/folder,ignore=shutil.ignore_patterns('evidence','__pycache__'))
    for al in (ROOT/board).glob('*.al'):shutil.copy2(al,source/al.name)
    # Recovery oracles consume the measured FAT diagnostic/control mapping
    # beside their candidate board, rather than deriving it from debug aliases.
    mapping=run.parents[1].parent/'fat-control-map.json'
    if mapping.exists():shutil.copy2(mapping,source.parent/mapping.name)
    evidence=dest/'evidence'/board;evidence.mkdir(parents=True)
    for name in ['inputs.json','settings.cfg','final.qor','resource-experiment.json',
                 f'MultimediaSystem_{board}_phy.area',f'MultimediaSystem_{board}_phy.ts',
                 f'MultimediaSystem_{board}_pr.timing',
                 f'MultimediaSystem_{board}_pr.db','resource-trial-bitgen.txt','resource_trial_bitgen_param.txt']:
        shutil.copy2(run/name,evidence/name)
    bit=run/f'MultimediaSystem_{board}_RESOURCE_TRIAL.bit';shutil.copy2(bit,dest/bit.name)
    original=ROOT/'build/resource-v1/base'/board
    shutil.copytree(original/'rtl',dest/'rollback-source'/board/'rtl')
    shutil.copy2(original/'frozen-inputs.json',dest/'rollback-source'/board/'frozen-inputs.json')
    # Unit oracles and generators can replay against their immutable reference
    # after extraction, rather than accidentally comparing an optimized RTL to itself.
    shutil.copytree(original,dest/'source/build/resource-v1/base'/board,
                    ignore=shutil.ignore_patterns('evidence','__pycache__'))
    delivered='clock_v1_medium3' if board=='media' else 'emergency_time_v7_high5_nopost'
    delivered_inputs=ROOT/board/'Runs'/('phy_'+delivered)/'inputs.json'
    shutil.copy2(delivered_inputs,evidence/'delivered-baseline-inputs.json')
# Preserve the exact pre-promotion references needed by cycle mirrors.
for reference in ('media_lba_lifetime/media','media_dsp_context/media',
                  'selected_9114_9043/media','selected_9114_9043/render',
                  'media_fat_sequence_mul_clear/media','sequence_mul_clear/render',
                  'media_fat_grouped_control/media','render_osd_combo/render',
                  'render_emergency_dsp/render','render_osd_cell32/render',
                  'render_osd_cell32_v2/render','render_osd_cell32_dsp/render',
                  'render_goertzel_history/render','render_history_ui_icons/render',
                  'render_history_icon_cell_shared_v2/render','render_audio_compact9/render',
                  'media_grouped_wav_fourcc/media','media_subtitle_context_bram/media',
                  'media_rgb_packer_unreset/media','media_browser_static9/media',
                  'media_packet32/media','media_fat_sector_lfn_v2/media',
                  'trial_packet32_scratch9_8811/media','trial_packet32_scratch9_8811/render'):
    origin=ROOT/'build/resource-v1'/reference
    if origin.exists():
        with contextlib.redirect_stdout(io.StringIO()):
            snapshot(origin,dest/'source/build/resource-v1'/reference)
        mapping=origin.parent/'fat-control-map.json'
        if mapping.exists():shutil.copy2(mapping,(dest/'source/build/resource-v1'/reference).parent/mapping.name)
shutil.copytree(ROOT/'tools/dual-board',dest/'source/tools/dual-board',ignore=shutil.ignore_patterns('__pycache__'))
shutil.copy2(ROOT/'tools/dual-board/reproduce-resource-checkpoint.ps1',dest/'REPRODUCE.ps1')
table_source=ROOT/'build/resource-v1/tables'
if table_source.exists():
    table_target=dest/'source/build/resource-v1/tables';table_target.mkdir(parents=True)
    for file in table_source.iterdir():
        if file.is_file() and file.suffix in ('.bits','.hex','.v','.json','.log'):
            shutil.copy2(file,table_target/file.name)
if (ROOT/'doc/dual-board/evidence').exists():shutil.copytree(ROOT/'doc/dual-board/evidence',dest/'evidence/system')
for name in ('candidate-matrix.json','candidate-matrix.md'):
    shutil.copy2(ROOT/'build/resource-v1'/name,dest/name)
shutil.copy2(ROOT/'doc/dual-board/resource-optimization-2026-10-14.md',dest/'EXPERIMENT.md')
shutil.copy2(ROOT/'doc/dual-board/resource-width-ranges.md',dest/'resource-width-ranges.md')
experiments=ROOT/'build/resource-v1'
for path in ('rom-equivalence','management-equivalence','combo-native-ui','combo_v3/tx-lifetime-equivalence',
             'render_text_coordinates_v2/text-coordinate-oracle','render_text_format_v2/text-coordinate-oracle',
             'media_browser_rom/browser-rom-generation','media_browser_rom/browser-cycle-equivalence',
             'media_fat_context/fat-context-native','media_bmp_fields/bmp-field-equivalence',
             'media_wav_fields/wav-field-equivalence','native-register-probe',
             'combo_v3/clock-production-equivalence','render_clock_palette/clock-production-equivalence',
             'render_ddc_timers/ddc-counter-equivalence','render_icon_rows/icon-address-oracle',
             'render_icon_rows/icon-row-oracle','render_text_palette/text-palette-address-oracle',
             'render_text_palette/text-coordinate-oracle','media_lba_lifetime/lba-lifetime-equivalence',
             'render_palettes_ddc/text-coordinate-oracle','render_palettes_ddc/clock-production-equivalence',
             'render_palettes_ddc/clock-frame-digits-oracle','bram-split-enable-probe',
             'dsp-register-probe-v3','dsp-register-probe-v4',
             'render_dsp_pixels/pixel-pipe-oracle','render_dsp_pixels/clock-production-equivalence',
             'header_bram_v3/header-equivalence-v2','render_full_palettes/pixel-pipe-oracle',
             'render_glyph9/glyph9-equivalence-v3','media_dsp_context/fat-dsp-equivalence',
             'sequence_dsp_v2/sequence-oracle-v2','sequence_dsp_v2/sequence-exact-v4',
             'sequence_mul_clear/sequence-oracle-v2','sequence_mul_clear/sequence-exact-v4',
             'bram-one-stage-probe','media_scratch_bram13_v2/fat-dsp-equivalence',
             'media_scratch_prefetch/fat-defined-scratch-equivalence',
             'media_scratch_prefetch/scratch-prefetch-arithmetic',
             'media_file_context_bram_v2/file-context-equivalence',
             'media_file_context_bram_v2/file-context-pending-stress',
             'media_file_context_bram_v2/fat-dsp-equivalence',
             'render_ui_dual_white9/ui-dual-palette-equivalence',
             'render_reader_rg/reader-rg-equivalence','render_reader_rg_prefetch/reader-rg-equivalence',
             'render_ui_pair_glyph32/glyph-pair-exact','render_emergency_width/shape-width-exact',
             'render_font_strips_v2/font-strips-equivalence',
             'media_geometry_width/geometry-width-equivalence-v2',
             'render_osd_combo/pixel-pipe-oracle','render_osd_combo/text-coordinate-oracle',
             'render_osd_combo/glyph-shape-combo-exact','render_osd_combo/audio-overlay-equivalence',
             'render_osd_combo/font-strips-equivalence','render_osd_combo/clock-frame-digits-oracle',
             'render_emergency_dsp/emergency-dsp-exact',
             'render_emergency_dsp/clock-frame-digits-oracle',
             'render_osd_cell32/audio-overlay-equivalence',
             'render_osd_cell32/pixel-pipe-oracle',
             'render_osd_cell32_v2/font-strips-equivalence',
             'render_osd_cell32_v2/audio-overlay-equivalence',
             'render_osd_cell32_v2/reused-ui-pixel-oracle',
             'render_osd_cell32_dsp/component-proofs',
             'render_goertzel_history/goertzel-history-equivalence',
             'render_goertzel_history9/goertzel-history-equivalence',
             'render_history_ui_icons/ui-cell-equivalence',
             'render_history_ui_icons/icon-address-oracle',
             'render_history_ui_icons/icon-row-oracle',
             'render_history_ui_icons/component-proofs',
             'render_history_icon_cell_shared_v2/icon-cell-share-equivalence',
             'render_history_icon_cell_shared_v2/icon-row-oracle',
             'render_history_icon_cell_shared_v2/component-proofs',
             'render_goertzel_shared_multiply/goertzel-history-equivalence',
             'render_audio_compact9/font-strips-equivalence',
             'render_audio_compact9/audio-overlay-equivalence',
             'render_audio_compact9/component-proofs',
             'render_audio_compact_state32/goertzel-history-equivalence',
             'media_fat_grouped_control/fat-dsp-equivalence',
             'media_fat_grouped_control/fat-control-recovery-v2',
             'media_fat_grouped_control/fat-raw-control-equivalence',
             'media_fat_grouped_lowbits/fat-control-recovery',
             'media_fat_grouped_lowbits/fat-dsp-equivalence',
             'media_fat_grouped_lowbits/fat-raw-control-equivalence',
             'media_setup_mul_regs/geometry-setup-mul-behavioral',
             'media_setup_mul_regs/geometry-setup-mul-native',
             'media_setup_mul_regs/bmp-setup-mul-behavioral',
             'media_setup_mul_regs/bmp-setup-mul-native',
             'media_setup_mul_regs/setup-mul-control-equivalence',
             'media_fat_grouped_lfn_rom/fat-dsp-equivalence',
             'media_fat_hierarchical_v5/fat-control-recovery',
             'media_fat_hierarchical_v5/fat-dsp-equivalence',
             'media_fat_mbr_stream/fat-dsp-equivalence',
             'media_fat_mbr_stream/mbr-stream-equivalence',
             'media_fat_mbr_local/fat-dsp-equivalence',
             'media_fat_mbr_local/mbr-stream-equivalence',
             'media_fat_cache32/fat-dsp-equivalence',
             'media_fat_cache32/cache32-word-equivalence-v2',
             'media_fat_cache32_scratch9_v2/fat-dsp-equivalence',
             'media_fat_cache32_scratch9_v2/bram9-hold-readback-on',
             'media_ui_snapshot_bytes/ui-snapshot-equivalence-v3',
             'media_subtitle_found_bram/subtitle-found-equivalence',
             'media_subtitle_context_bram/subtitle-found-equivalence',
             'media_subtitle_context_bram/subtitle-context-words',
             'media_lba_skip9/lba-lifetime-equivalence',
             'media_lba_prepare_shared/lba-lifetime-equivalence',
             'media_grouped_wav_fields/wav-field-equivalence',
             'media_grouped_wav_fourcc/wav-field-equivalence',
             'media_wav_subtitle_context/component-proofs',
             'media_fat_constant_fields/fat-dsp-equivalence',
             'media_fat_constant_fields/mbr-stream-equivalence',
             'media_fat_grouped_gray/fat-dsp-equivalence',
             'media_fat_grouped_gray/fat-control-recovery',
             'media_rgb_packer_share/rgb-packer-share-equivalence',
             'media_rgb_packer_unreset/rgb-packer-share-equivalence',
             'media_rgb_packer_eager/rgb-packer-share-equivalence',
             'media_fat_constant_fields/mbr-constant-equivalence-v2',
             'media_grouped_bmp_fields/bmp-field-equivalence',
             'media_subtitle_current_bram_v2/subtitle-found-equivalence',
             'media_subtitle_current_bram_v2/subtitle-context-words',
             'media_fat_private_resets/fat-dsp-equivalence',
             'media_fat_private_resets/mbr-stream-equivalence',
             'media_fat_walk_widths/fat-dsp-equivalence',
             'media_fat_walk_widths/mbr-stream-equivalence',
             'media_browser_static9/browser-rom-generation',
             'media_browser_menu32/browser-menu-rom-equivalence',
             'media_browser_menu32/browser-cycle-equivalence',
             'media_geometry_division_share/geometry-division-equivalence',
             'media_geometry_division_share/setup-mul-control-equivalence',
             'media_fat_hop_share/fat-dsp-equivalence',
             'media_fat_hop_share/fat-hop-boundary-equivalence',
             'media_geometry_lifetime_share/geometry-lifetime-equivalence',
             'media_geometry_lifetime_share/setup-mul-control-equivalence',
             'media_geometry_bank_share/geometry-bank-equivalence',
             'media_geometry_bank_share/setup-mul-control-equivalence',
             'media_parser_mbr_combo/bmp-field-equivalence',
             'media_parser_mbr_combo/bmp-field-native',
             'media_parser_mbr_combo/wav-field-equivalence',
             'media_parser_mbr_combo/fat-dsp-equivalence',
             'media_parser_mbr_combo/fat-owner-equivalence-v2',
             'media_parser_mbr_combo/mbr-stream-equivalence',
             'media_storage_context_bram/storage-context-equivalence',
             'media_storage_context_bram/storage-context-equivalence-v2',
             'media_storage_context_owned/storage-context-equivalence-v2',
             'media_fat_sector_lfn/sector-lfn-equivalence',
             'media_fat_sector_lfn/sector-lfn-equivalence-v2',
             'media_fat_sector_lfn_v2/sector-lfn-equivalence-v2',
             'media_fat_sector_lfn_v2/fat-dsp-equivalence',
             'media_fat_cache32_scratch9_v2/bram9-hold-native-writes-readback-on',
             'media_packet32/packet32-equivalence',
             'media_packet32/packet32-fast-clock',
             'media_packet32/packet32-fast-clock-v2',
             'media_packet32_scratch9/fat-dsp-equivalence',
             'media_fat_cache32_scratch9_v2/bram9-hold-native-writes-readback-off',
             'media_fat_walk_arithmetic/fat-dsp-equivalence',
             'media_fat_walk_arithmetic_v2/fat-dsp-equivalence',
             'media_bmp_pixel_assembly/bmp-pixel-assembly-equivalence',
             'media_bmp_pixel_assembly/bmp-pixel-assembly-equivalence-v2',
             'media_stream_output_bram/stream-output-bram-equivalence',
             'media_stream_output_bram/stream-output-bram-equivalence-v2',
             'media_stream_walk_packet/fat-dsp-equivalence',
             'media_stream_walk_packet/packet32-fast-clock-v2',
             'media_stream_walk_packet/stream-output-bram-equivalence-v2',
             'media_stream_walk_scratch8/fat-dsp-equivalence',
             'media_fat_timeout_lfsr/timeout-lfsr-proof',
             'media_fat_timeout_lfsr/timeout-lfsr-equivalence',
             'media_fat_timeout_lfsr/fat-dsp-equivalence'):
    origin=experiments/path
    if origin.exists():
        def evidence_ignore(folder,names):
            return [name for name in names if (Path(folder)/name).is_file()
                    and Path(name).suffix.lower() not in ('.txt','.log','.json','.v','.vh','.hex')]
        shutil.copytree(origin,dest/'evidence/regressions'/path,ignore=evidence_ignore)
for physical in experiments.glob('*/[mr]*/Runs/phy_*'):
    evidence=dest/'evidence/candidates'/physical.relative_to(experiments)
    evidence.mkdir(parents=True,exist_ok=True)
    for file in physical.iterdir():
        if file.is_file() and (file.name in ('inputs.json','settings.cfg','console.txt','final.qor','resource-experiment.json')
                              or file.suffix in ('.area','.ts') or file.name.endswith(('.error.f','_pr.timing'))):
            shutil.copy2(file,evidence/file.name)
for synth in experiments.glob('*/[mr]*/Runs/syn_*'):
    log=synth/'console.txt'
    if not log.exists():continue
    if 'Oops! coredump' not in log.read_text(errors='replace') and not list(synth.glob('*.error.f')):continue
    target=dest/'evidence/candidates'/synth.relative_to(experiments);target.mkdir(parents=True,exist_ok=True)
    for name in ('inputs.json','settings.cfg','console.txt'):
        if (synth/name).is_file():shutil.copy2(synth/name,target/name)
# Closeout evidence includes stopped workers; partial runs are never promoted.
shutil.copytree(experiments/'jobs',dest/'evidence/jobs')
for name in ('native-bram9-address-evidence.json','closeout.json'):
    if (experiments/name).exists():shutil.copy2(experiments/name,dest/name)
rollback=ROOT/'build/emergency-time-v1/release_emergency_time_trial.zip'
if rollback.exists():
    (dest/'rollback').mkdir()
    shutil.copy2(rollback,dest/'rollback'/rollback.name)
manifest=dict(protocol='1.9',status='EXPERIMENTAL_CHECKPOINT',
              target_complete=all(r['target_90_percent'] for r in reports.values()),
              formal_qualification=False,boards=reports,
              alternatives=alternatives,
              files={str(f.relative_to(dest)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest()
                     for f in sorted(dest.rglob('*')) if f.is_file()})
(dest/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
archive=shutil.make_archive(str(dest),'zip',root_dir=dest)
print(json.dumps(dict(archive=archive,target_complete=manifest['target_complete'],
                      sha256=hashlib.sha256(Path(archive).read_bytes()).hexdigest()),ensure_ascii=False))
