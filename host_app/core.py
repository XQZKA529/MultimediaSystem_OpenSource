"""Media conversion and checked SD-card deployment for the desktop application."""
from __future__ import annotations
import ctypes
import hashlib
import json
import os
import shutil
import sys
import tempfile
import wave
from pathlib import Path
from PIL import Image, ImageOps
import miniaudio

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
from convert_fpga_bmp import flatten_to_rgb, resize_image
from convert_sd_overlay import write_bmp
from fat32 import open_volume, root_entries


def check_subtitle(value):
    if len(value) > 256 or any(not 32 <= ord(c) <= 126 for c in value):
        raise ValueError('字幕必须为最多 256 个可打印 ASCII 字符，不能包含中文或换行')
    return value


def check_sources(project):
    pictures = project.get('pictures', [])
    audios = project.get('audio', [])
    if len(pictures) > 256:
        raise ValueError('普通图片不能超过 256 张')
    if len(audios) + sum(bool(p.get('audio')) for p in pictures) > 64:
        raise ValueError('普通音频不能超过 64 首')
    paths = [p['path'] for p in pictures] + [p['audio'] for p in pictures if p.get('audio')] + audios
    if project.get('logo'):
        paths.append(project['logo'])
    for path in paths:
        if not Path(path).is_file():
            raise ValueError(f'源文件不存在：{path}')
    for p in pictures:
        check_subtitle(p.get('subtitle', ''))
        if p.get('mode', 'contain') not in ('contain', 'stretch', 'original'):
            raise ValueError('图片转换模式无效')
    if paths and not pictures and not audios and not project.get('logo'):
        raise ValueError('没有素材')


def image_convert(source, dest, mode):
    with Image.open(source) as image:
        rgb = flatten_to_rgb(image, (0, 0, 0))
        if mode == 'original':
            if not (1 <= rgb.width <= 4096 and 1 <= rgb.height <= 4096):
                raise ValueError(f'原图尺寸 {rgb.width}×{rgb.height} 超过 FPGA 限制 1–4096')
            output = rgb
        else:
            output = resize_image(rgb, mode, (0, 0, 0))
        output.save(dest, 'BMP')
    verify_bmp(dest)


def verify_bmp(path):
    import struct
    data = Path(path).read_bytes()
    if len(data) < 54:
        raise ValueError('BMP 数据不完整')
    size, offset, dib, w, h, planes, bits, compression = struct.unpack_from('<IxxxxIIiiHHI', data, 2)
    if not (data[:2] == b'BM' and size == len(data) and dib >= 40 and 1 <= w <= 4096 and 1 <= h <= 4096 and planes == 1 and bits == 24 and compression == 0 and offset >= 14 + dib and offset + ((w * 3 + 3) & ~3) * h <= len(data)):
        raise ValueError('BMP 不符合 FPGA 格式')


def estimate_size(project):
    """Estimate media bytes; unknown audio duration is reported separately."""
    total, unknown = 0, 0
    for item in project.get('pictures', []):
        try:
            if item.get('mode', 'contain') == 'original':
                with Image.open(item['path']) as image:
                    width, height = ImageOps.exif_transpose(image).size
            else:
                width, height = 1280, 720
            total += 54 + ((width * 3 + 3) & ~3) * height
            total += len(item.get('subtitle', '').encode('utf-8'))
        except (OSError, ValueError):
            unknown += 1
    if project.get('logo'):
        total += 12342
    audio = project.get('audio', []) + [x['audio'] for x in project.get('pictures', []) if x.get('audio')]
    for path in audio:
        try:
            info = miniaudio.get_file_info(str(path))
            total += int(info.duration * 48000 * 4) + 128
        except (OSError, ValueError, miniaudio.DecodeError):
            unknown += 1
    return total, unknown


def audio_convert(source, dest, channels='auto'):
    try:
        info = miniaudio.get_file_info(str(source))
        if channels == 'auto':
            target_channels = 1 if info.nchannels == 1 else 2
        elif channels in ('1', '2', 1, 2):
            target_channels = int(channels)
        else:
            raise ValueError('输出声道必须为自动、单声道或立体声')
        if info.duration <= 0:
            raise ValueError('音频没有有效采样数据')
        with wave.open(str(dest), 'wb') as output:
            output.setnchannels(target_channels)
            output.setsampwidth(2)
            output.setframerate(48000)
            samples = miniaudio.stream_file(str(source), output_format=miniaudio.SampleFormat.SIGNED16,
                                            nchannels=target_channels, sample_rate=48000, frames_to_read=8192)
            try:
                for chunk in samples:
                    output.writeframesraw(chunk.tobytes())
            finally:
                samples.close()
        with wave.open(str(dest), 'rb') as output:
            if (output.getframerate(), output.getsampwidth(), output.getnchannels()) != (48000, 2, target_channels) or not output.getnframes():
                raise ValueError('输出 WAV 格式无效或没有音频数据')
    except (miniaudio.DecodeError, miniaudio.MiniaudioError) as exc:
        raise ValueError('音频解码失败，请检查 MP3/WAV 文件：' + str(exc)) from exc


def prepare(project, folder, progress=lambda x: None):
    check_sources(project)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    manifest = []
    for i, p in enumerate(project.get('pictures', []), 1):
        stem = f'P{i:07d}'
        name = stem + '.BMP'
        progress(f'转换图片 {i}/{len(project["pictures"])}：{Path(p["path"]).name}')
        image_convert(p['path'], folder / name, p.get('mode', 'contain'))
        manifest.append(name)
        if p.get('subtitle'):
            (folder / (stem + '.TXT')).write_bytes(check_subtitle(p['subtitle']).encode('ascii'))
            manifest.append(stem + '.TXT')
        if p.get('audio'):
            audio_convert(p['audio'], folder / (stem + '.WAV'), project.get('channels', 'auto'))
            manifest.append(stem + '.WAV')
    for i, path in enumerate(project.get('audio', []), 1):
        name = f'M{i:07d}.WAV'
        progress(f'转换音频 {i}/{len(project["audio"])}：{Path(path).name}')
        audio_convert(path, folder / name, project.get('channels', 'auto'))
        manifest.append(name)
    if project.get('logo'):
        progress('转换台标')
        with Image.open(project['logo']) as img:
            img = ImageOps.exif_transpose(img)
            img = flatten_to_rgb(img, (0, 0, 0))
            write_bmp(img, folder / 'OVERLAY.BMP')
        verify_bmp(folder / 'OVERLAY.BMP')
        if (folder / 'OVERLAY.BMP').stat().st_size != 12342:
            raise ValueError('台标文件大小不正确')
        manifest.append('OVERLAY.BMP')
    if not manifest:
        raise ValueError('请先添加素材')
    return manifest


def drives():
    if os.name != 'nt':
        return []
    kernel = ctypes.windll.kernel32
    result = []
    for i in range(26):
        root = f'{chr(65+i)}:\\'
        if kernel.GetDriveTypeW(root) != 2:
            continue
        label, fs = ctypes.create_unicode_buffer(261), ctypes.create_unicode_buffer(261)
        if kernel.GetVolumeInformationW(root, label, 261, None, None, None, fs, 261):
            result.append((root, label.value, fs.value))
    return result


def volume_serial(root):
    serial = ctypes.c_ulong()
    ok = ctypes.windll.kernel32.GetVolumeInformationW(root, None, 0, ctypes.byref(serial), None, None, None, 0)
    if not ok:
        raise ValueError('无法读取目标卷标识，请确认磁盘仍然连接')
    return serial.value


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.digest()


def volume_entries(root):
    try:
        with open_volume(root[0]) as stream:
            return root_entries(stream)
    except PermissionError as e:
        raise ValueError('无法读取磁盘目录项，请以管理员身份启动程序后重试') from e


def deploy(project, root, progress=lambda x: None):
    available = {d[0].upper(): d for d in drives()}
    root = root.upper()
    if root not in available or available[root][2].upper() != 'FAT32':
        raise ValueError('请选择当前连接的 FAT32 可移动磁盘')
    serial = volume_serial(root)
    if volume_entries(root) or any(Path(root).iterdir()):
        raise ValueError('SD 卡根目录必须为空；请先自行备份并清空')
    with tempfile.TemporaryDirectory(prefix='fpga_media_') as tmp:
        manifest = prepare(project, tmp, progress)
        if shutil.disk_usage(root).free < sum((Path(tmp) / n).stat().st_size for n in manifest):
            raise ValueError('SD 卡剩余空间不足')
        # Verify again before creating the first file, avoiding accidental changes to another volume.
        if root not in {d[0].upper() for d in drives()} or volume_serial(root) != serial or volume_entries(root) or any(Path(root).iterdir()):
            raise ValueError('目标磁盘已改变或根目录不再为空')
        for name in manifest:
            if volume_serial(root) != serial:
                raise ValueError('目标磁盘已更换，停止写入')
            progress('写入 ' + name)
            with open(Path(tmp) / name, 'rb') as src, open(Path(root) / name, 'xb') as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
        progress('核验文件内容及 FAT32 目录顺序')
        for name in manifest:
            if digest(Path(tmp) / name) != digest(Path(root) / name):
                raise ValueError(f'文件内容核验失败：{name}')
        actual = [n.upper() for n, is_dir in volume_entries(root) if not is_dir and n.upper().endswith('.BMP') and n.upper() != 'OVERLAY.BMP']
        expected = [n for n in manifest if n.endswith('.BMP') and n != 'OVERLAY.BMP']
        if actual != expected:
            raise ValueError(f'FAT32 图片目录顺序核验失败：期望 {expected}，实际 {actual}。请备份后重新准备空的 FAT32 卡。')
    return len(manifest)
