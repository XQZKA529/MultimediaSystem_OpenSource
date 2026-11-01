"""Read-only FAT32 volume capture for the media image-switch probe.

Windows example (the volume is opened only with 'rb'):
    python tools/dual-board/capture-sd-image-probe.py --volume F: --out media/build/evidence/sd-card-image-probe

Captures the volume boot sector, root directory, first sector of each root
file, and the first ordinary BMP's full contents. It does not capture the
physical MBR; LBA zero in this fixture is the FAT32 volume boot sector.
"""
import argparse
import json
import struct
from pathlib import Path


def capture(volume, output):
    output.mkdir(parents=True, exist_ok=True)
    with open("\\\\.\\" + volume, "rb", buffering=0) as disk:
        def sectors(lba, count=1):
            disk.seek(lba * 512)
            data = disk.read(count * 512)
            if len(data) != count * 512:
                raise ValueError(f"Short volume read at sector {lba}")
            return data

        boot = sectors(0)
        u16 = lambda data, offset: struct.unpack_from("<H", data, offset)[0]
        u32 = lambda data, offset: struct.unpack_from("<I", data, offset)[0]
        if boot[510:] != b"\x55\xaa" or u16(boot, 11) != 512 or u16(boot, 17) != 0:
            raise ValueError("Expected a 512-byte-sector FAT32 volume")
        spc, reserved, fats = boot[13], u16(boot, 14), boot[16]
        fat_sectors, root = u32(boot, 36), u32(boot, 44)
        data_lba = reserved + fats * fat_sectors
        fat = sectors(reserved, fat_sectors)
        captured = {0: boot}
        entries, visited, lfn = [], set(), []
        cluster, end = root, False

        def next_cluster(value):
            return u32(fat, value * 4) & 0x0fffffff

        def add(lba, count=1):
            block = sectors(lba, count)
            for i in range(count):
                captured[lba + i] = block[i * 512:(i + 1) * 512]
            return block

        while 2 <= cluster < 0x0ffffff8 and not end:
            if cluster in visited:
                raise ValueError("Root directory cluster cycle")
            visited.add(cluster)
            block = add(data_lba + (cluster - 2) * spc, spc)
            add(reserved + cluster * 4 // 512)
            for offset in range(0, len(block), 32):
                entry = block[offset:offset + 32]
                if entry[0] == 0:
                    end = True
                    break
                if entry[0] == 0xe5:
                    lfn = []
                    continue
                if entry[11] == 15:
                    text = b"".join(entry[a:a + 2] for a in (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30))
                    lfn.insert(0, text.decode("utf-16le", errors="replace"))
                    continue
                name = ("".join(lfn).split("\0")[0] if lfn else
                        entry[:8].decode("ascii", errors="replace").rstrip() + "." +
                        entry[8:11].decode("ascii", errors="replace").rstrip())
                lfn = []
                if entry[11] & 0x18:
                    continue
                start = u16(entry, 26) + (u16(entry, 20) << 16)
                size = u32(entry, 28)
                if start < 2 or size == 0:
                    continue
                lba = data_lba + (start - 2) * spc
                head = add(lba)
                entries.append(dict(name=name, cluster=start, size=size, lba=lba,
                                    header_hex=head[:54].hex()))
            cluster = next_cluster(cluster)

        first = next(e for e in entries if e["name"].upper().endswith(".BMP") and
                     e["name"].upper() != "OVERLAY.BMP")
        cluster, remaining, visited = first["cluster"], first["size"], set()
        while remaining:
            if cluster in visited or cluster < 2 or cluster >= 0x0ffffff8:
                raise ValueError("Invalid first BMP cluster chain")
            visited.add(cluster)
            count = min(spc, (remaining + 511) // 512)
            add(data_lba + (cluster - 2) * spc, count)
            add(reserved + cluster * 4 // 512)
            if len(captured) > 512:
                raise ValueError("Capture exceeds the SD test model's 512-sector capacity")
            remaining = max(0, remaining - count * 512)
            cluster = next_cluster(cluster)

    lbas = sorted(captured)
    (output / "lbas.hex").write_text("\n".join(f"{n:08x}" for n in lbas) + "\n", encoding="ascii")
    (output / "bytes.hex").write_text("\n".join(f"{b:02x}" for n in lbas for b in captured[n]) + "\n", encoding="ascii")
    manifest = dict(source_volume=volume, sector_count=len(lbas), spc=spc,
                    data_lba=data_lba, entries=entries)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Captured {len(lbas)} volume sectors, {len(entries)} files; first BMP: {first['name']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--volume", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if len(args.volume) != 2 or not args.volume[0].isalpha() or args.volume[1] != ":":
        parser.error("--volume must be a Windows drive letter, for example F:")
    capture(args.volume, args.out)
