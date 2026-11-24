"""Compare stock ExCable, a four-frame release, and Cabby in rotated order."""

import argparse
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("stock", "prototype", "cabby", "ruby", "driver", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--rates", type=int, nargs="+", default=[1200, 8000])
    args = parser.parse_args()
    bench = Path(__file__).resolve().parents[1] / "run.py"
    variants = ("stock", "prototype", "cabby")
    for repeat in range(3):
        for level, rate in enumerate(args.rates):
            for position in range(3):
                name = variants[(repeat + level + position) % 3]
                print(f"Round {repeat + 1}: {name} at {rate} publications/s", flush=True)
                is_cabby = name == "cabby"
                subprocess.run([
                    sys.executable, str(bench), "steady",
                    "--servers", "cabby" if is_cabby else "excable",
                    "--cabby" if is_cabby else "--excable", str(getattr(args, name).resolve()),
                    "--driver", str(args.driver.resolve()), "--ruby", str(args.ruby.resolve()),
                    "--out", str(args.out.resolve() / name / str(repeat + 1)),
                    "--rounds", "1", "--levels", str(rate), "--clients", "240",
                    "--publishers", "8", "--warmup", "3s", "--duration", "10s",
                    "--idle", "1s", "--drain", "6s",
                ], check=True)


if __name__ == "__main__":
    main()
