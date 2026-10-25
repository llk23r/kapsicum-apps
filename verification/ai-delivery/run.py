#!/usr/bin/env python3
"""Build actual public Kapp sources and run isolated, parallel regression checks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
PUBLIC = HERE.parents[1]


def source_hashes():
    sources = sorted({path.resolve() for path in (HERE / "Sources").rglob("*.swift")})
    return {str(path.relative_to(PUBLIC)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources}


def execute(name, command, timeout=120, env=None):
    started = time.monotonic()
    try:
        run = subprocess.run(command, text=True, capture_output=True, timeout=timeout, env=env)
        result = {"name": name, "exit_code": run.returncode,
                  "output": run.stdout + run.stderr}
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        result = {"name": name, "exit_code": None, "timed_out": True,
                  "output": text(error.stdout) + text(error.stderr)}
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, help="Write JSON results outside the source package.")
    args = parser.parse_args()
    before = source_hashes()
    report = {"production_source_transformed_for_tests": False,
              "provider_requests": 0, "live_archive_accessed": False,
              "execution": "three executables in parallel; cases use task groups and isolated UUID fixtures",
              "source_hashes": before}
    with tempfile.TemporaryDirectory(prefix="xactivity-ai-verification-") as temporary:
        scratch = Path(temporary) / "build"
        environment = dict(os.environ)
        environment["CLANG_MODULE_CACHE_PATH"] = str(Path(temporary) / "module-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = environment["CLANG_MODULE_CACHE_PATH"]
        base = ["swift", "build", "--package-path", str(HERE),
                "--scratch-path", str(scratch), "--cache-path", str(Path(temporary) / "cache"),
                "--config-path", str(Path(temporary) / "config"),
                "--security-path", str(Path(temporary) / "security")]
        build = execute("build", base, timeout=300, env=environment)
        report["build"] = build
        if build["exit_code"] == 0:
            binary_path = subprocess.run(base + ["--show-bin-path"], check=True,
                                         text=True, capture_output=True, env=environment).stdout.strip()
            db_root = Path(temporary) / "database-fixtures"
            db_root.mkdir()
            commands = [("StoreProof", [str(Path(binary_path) / "StoreProof")]),
                        ("ReportMediaProof", [str(Path(binary_path) / "ReportMediaProof")]),
                        ("DatabaseProof", [str(Path(binary_path) / "DatabaseProof"), str(db_root)])]
            with ThreadPoolExecutor(max_workers=len(commands)) as pool:
                report["runs"] = list(pool.map(lambda item: execute(*item), commands))
            report["database_fixtures_removed"] = not any(db_root.iterdir())
            expected = {"StoreProof": 38, "ReportMediaProof": 10, "DatabaseProof": 6}
            for run in report["runs"]:
                if run["name"] == "DatabaseProof" and run["exit_code"] == 0:
                    cases = json.loads(run["output"])
                    run["passed_cases"] = sum(item["passed"] is True for item in cases)
                else:
                    run["passed_cases"] = sum(line.startswith("PASS ") for line in run["output"].splitlines())
                run["expected_cases"] = expected[run["name"]]
                run["complete"] = run["passed_cases"] == run["expected_cases"]
    report["sources_unchanged"] = source_hashes() == before
    report["passed"] = (report["build"]["exit_code"] == 0
                        and all(result["exit_code"] == 0 and result["complete"] for result in report.get("runs", []))
                        and report.get("database_fixtures_removed", False)
                        and report["sources_unchanged"])
    if args.results:
        args.results.parent.mkdir(parents=True, exist_ok=True)
        args.results.write_text(json.dumps(report, indent=2) + "\n")
    for result in [report["build"]] + report.get("runs", []):
        print(f"{result['name']}: {'PASS' if result['exit_code'] == 0 else 'FAIL'} ({result['elapsed_seconds']}s)")
        print(result["output"].rstrip())
    print("Production sources unchanged:", report["sources_unchanged"])
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
