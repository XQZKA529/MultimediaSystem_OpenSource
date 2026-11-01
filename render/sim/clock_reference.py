"""Independent Gregorian boundary vectors for the entire supported century."""
import argparse
from datetime import datetime, timedelta
from pathlib import Path


def pack(t):
    value = t.year - 2000
    for width, item in ((4, t.month), (5, t.day), (5, t.hour), (6, t.minute), (6, t.second)):
        value = (value << width) | item
    return value


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    current = datetime(2000, 1, 1, 23, 59, 59)
    values = []
    while current.year < 2100:
        following = current + timedelta(seconds=1)
        if following.year == 2100:
            following = datetime(2000, 1, 1)
        values.append(f"{(pack(current) << 33) | pack(following):017x}\n")
        current += timedelta(days=1)
    assert len(values) == 36525
    args.out.write_text("".join(values), encoding="ascii")
    print("Gregorian oracle: 36525 day boundaries, including century wrap")
