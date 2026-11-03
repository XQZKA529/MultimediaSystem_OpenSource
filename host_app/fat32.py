"""FAT32 root-directory enumeration, matching the FPGA's physical scan order."""
import struct


def u16(b, n):
    return struct.unpack_from('<H', b, n)[0]


def u32(b, n):
    return struct.unpack_from('<I', b, n)[0]


def root_entries(stream):
    """Read an already opened FAT32 volume or a FAT32 partition image.

    Returns live short names in on-disk order. The host creates only 8.3 names,
    so a long filename is unnecessary for verifying its own output.
    """
    stream.seek(0)
    b = stream.read(512)
    if len(b) != 512 or b[510:512] != b'\x55\xaa':
        raise ValueError('无法读取有效的 FAT32 引导扇区')
    sector = u16(b, 11)
    cluster_sectors = b[13]
    reserved, fats, fat_size, root = u16(b, 14), b[16], u32(b, 36), u32(b, 44)
    total = u16(b, 19) or u32(b, 32)
    if sector != 512 or not cluster_sectors or cluster_sectors & (cluster_sectors - 1) or not reserved or not fats or not fat_size or root < 2:
        raise ValueError('不支持的 FAT32 卷或逻辑扇区不是 512 字节')
    data_start = reserved + fats * fat_size
    clusters = (total - data_start) // cluster_sectors
    if clusters < 65525 or root >= clusters + 2:
        raise ValueError('目标不是有效的 FAT32 卷')
    names, seen = [], set()
    cluster = root
    while 2 <= cluster < 0x0ffffff8:
        if cluster in seen or cluster >= clusters + 2:
            raise ValueError('FAT32 根目录簇链无效')
        seen.add(cluster)
        stream.seek((data_start + (cluster - 2) * cluster_sectors) * sector)
        data = stream.read(cluster_sectors * sector)
        if len(data) != cluster_sectors * sector:
            raise ValueError('根目录读取不完整')
        for p in range(0, len(data), 32):
            e = data[p:p+32]
            if e[0] == 0:
                return names
            if e[0] == 0xe5 or e[11] == 0x0f or e[11] & 0x08:
                continue
            base = e[:8].decode('ascii', errors='replace').rstrip()
            ext = e[8:11].decode('ascii', errors='replace').rstrip()
            names.append((base + ('.' + ext if ext else ''), bool(e[11] & 0x10)))
        fat_offset = cluster * 4
        stream.seek((reserved + fat_offset // sector) * sector)
        raw = stream.read(sector)
        if len(raw) != sector:
            raise ValueError('FAT 读取不完整')
        cluster = u32(raw, fat_offset % sector) & 0x0fffffff
        if cluster < 2 or cluster == 0x0ffffff7:
            raise ValueError('FAT32 根目录簇链损坏')
    return names


def open_volume(letter):
    return open('\\\\.\\' + letter.upper().rstrip(':\\') + ':', 'rb', buffering=0)
