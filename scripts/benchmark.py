"""Run optimized native UI workloads with a private, generated project. No user documents are opened."""
import argparse
import ctypes
import time
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--bundle", type=Path, help="use an already-built benchmark app")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--output", type=Path)
parser.add_argument("--extra-folders", type=int, default=0, help="additional sibling folders for the overview")
parser.add_argument("--open-file", "--image", dest="initial_file", type=Path, help="open a file at launch; idle then measures that document")
parser.add_argument("--batch-files", type=int, default=0, help="open this many generated large code files together at launch")
parser.add_argument("--matches-on-line", type=int, default=1, help="repeat the search term on the one matching line")
args = parser.parse_args()
if args.matches_on_line < 1:
    parser.error("--matches-on-line must be positive")
if args.bundle:
    bundle = args.bundle.resolve()
else:
    subprocess.run(["bash", "scripts/build.sh", "--benchmark"], cwd=repo, check=True)
    bundle = repo / ".build/benchmark/Folio.app"

# Sampling tool only. Production Folio uses no process enumeration or private system interfaces.
class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16), ("values", ctypes.c_uint64 * 10)]

system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
helpers = {"com.apple.WebKit.GPU", "com.apple.WebKit.Networking", "com.apple.WebKit.WebContent"}

def memory_sample(binary):
    processes = [row.split(None, 2) for row in subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines()]
    main = next((int(pid) for pid, _, command in processes if command == str(binary)), None)
    if main is None:
        return None
    total = 0
    web = 0
    for pid, parent, command in processes:
        pid = int(pid)
        name = command.rsplit("/", 1)[-1]
        related_web = name in helpers and system.responsibility_get_pid_responsible_for_pid(pid) == main
        if pid != main and not related_web and not (name == "rg" and int(parent) == main):
            continue
        usage = Usage()
        if system.proc_pid_rusage(pid, 0, ctypes.byref(usage)) == 0:
            total += usage.values[7]
            if related_web:
                web += usage.values[7]
    return total / 1048576, web / 1048576

with tempfile.TemporaryDirectory(prefix="Folio-benchmark-") as tmp:
    project = Path(tmp) / "project"
    project.mkdir()
    (project / "long.txt").write_text("An ordinary line of text with a few words.\n" * 75000)
    for i in range(8):
        (project / f"code-{i}.swift").write_text(f"// file {i}\n" + 'let entry = "hello" // sample 1234\n' * 9000)
    for i in range(6):
        (project / f"notes-{i}.md").write_text(f"# Notes {i}\n\n" + "A paragraph with **bold**, [example](./README.md), and `inline code`.\n\n" * 1400)
    for i in range(args.extra_folders):
        (project / f"folder-{i}").mkdir()
    matching_line = " ".join(["unique-folio-benchmark-line"] * args.matches_on_line)
    for directory in range(60):
        folder = project / "library" / str(directory)
        folder.mkdir(parents=True)
        for i in range(150):
            (folder / f"entry-{i}.txt").write_text(matching_line if directory == i == 0 else "data")
    launch_files = []
    if args.initial_file:
        fixture_dir = Path(tmp) / "document"
        fixture_dir.mkdir()
        fixture = shutil.copyfile(args.initial_file, fixture_dir / args.initial_file.name)
        launch_files.append(str(fixture))
    if args.batch_files:
        bulk = Path(tmp) / "batch"
        bulk.mkdir()
        for i in range(args.batch_files):
            doc = bulk / f"module-{i}.swift"
            with doc.open("w") as f:
                for line in range(65000):
                    f.write(f'let entry_{line} = "module {i}, value {line}" // generated source\n')
            launch_files.append(str(doc))
    rows = {}
    for n in range(args.runs):
        log, err = Path(tmp) / f"{n}.out", Path(tmp) / f"{n}.err"
        cmd = ["open", "-n", "-W", "--stdout", str(log), "--stderr", str(err),
               "--env", f"FOLIO_BENCH_ROOT={project}", str(bundle)]
        if launch_files:
            cmd += ["--args", *launch_files]
        process = subprocess.Popen(cmd)
        deadline = time.monotonic() + 240
        samples = []
        while process.poll() is None:
            sample = memory_sample(bundle / "Contents/MacOS/Folio")
            if sample:
                samples.append(sample)
            if time.monotonic() > deadline:
                raise TimeoutError(log.read_text())
            time.sleep(0.12)
        if process.returncode:
            raise RuntimeError(err.read_text())
        if samples:
            rows.setdefault("sampled_peak", []).append({"MiB": round(max(x[0] for x in samples), 2),
                "webkit_peak_MiB": round(max(x[1] for x in samples), 2)})
        result = log.read_text()
        if "BENCHMARK COMPLETE" not in result:
            raise RuntimeError(result + err.read_text())
        for line in result.splitlines():
            if line.startswith("BENCH "):
                _, stage, ms, mib = line.split()
                rows.setdefault(stage, []).append({"ms": float(ms), "MiB": float(mib)})
    print("Stage       median ms   median main-process physical footprint (MiB)")
    for stage, samples in rows.items():
        if stage == "sampled_peak":
            print(f"Sampled peak including WebKit helpers and rg: {statistics.median(x['MiB'] for x in samples):.2f} MiB")
            continue
        print(f"{stage:<12}{statistics.median(x['ms'] for x in samples):9.2f}{statistics.median(x['MiB'] for x in samples):12.2f}")
    if args.output:
        args.output.write_text(json.dumps(rows, indent=2)+"\n")
