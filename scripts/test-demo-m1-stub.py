"""Offline regression for demo-m1.sh; all external commands are local stubs."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
CYGPATH = Path(r"C:\Program Files\Git\usr\bin\cygpath.exe")
SOURCE = Path(__file__).with_name("demo-m1.sh")

CURL_PY = r'''import json, os, pathlib, sys
args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1] if name in args else None
out = pathlib.Path(option('-o'))
url = args[-1]
state = pathlib.Path(os.environ['STUB_STATE'])
scenario = os.environ['STUB_SCENARIO']
code, body = '200', b'{}'
if url.endswith('/actuator/health'):
    body = json.dumps({'status': 'DOWN' if scenario == 'health_down' else 'UP'}).encode()
elif '/api/health' in url:
    data_root = os.environ['STUB_DATA_ROOT']
    if scenario == 'wrong_root': data_root += '-other'
    body = json.dumps({'status': 'UP', 'config': {'dataRoot': data_root}}).encode()
elif '-F' in args:
    count_file = state / 'uploads'
    count = int(count_file.read_text()) + 1 if count_file.exists() else 1
    count_file.write_text(str(count))
    upload_file = next(a.split('@', 1)[1].split(';', 1)[0] for a in args if a.startswith('file=@'))
    (state / 'sample').write_bytes(pathlib.Path(upload_file).read_bytes())
    resource = f'00000000-0000-7000-8000-{count:012d}'
    content = '00000000-0000-7000-8000-000000000099'
    duplicate = count > 1
    if scenario == 'missing_id' and count == 1: resource = None
    if scenario == 'bad_dedup' and count == 2: duplicate = False
    body = json.dumps({'id': resource, 'contentId': content, 'deduplicated': duplicate}).encode()
    code = '201'
elif '/content?inline=true' in url or 'size=201' in url or 'size=0' in url or 'not-a-uuid' in url:
    code = '400'
elif '/content' in url:
    body = (state / 'sample').read_bytes()
    if scenario == 'bad_download': body += b'corrupt'
elif '/restore' in url:
    (state / 'deleted').unlink(missing_ok=True)
elif url.endswith('/resources/trash') and '-X' in args and args[args.index('-X') + 1] == 'DELETE':
    code = '400'
elif '/resources/trash?confirm=true' in url:
    body = b'{"deletedCount":0}'
elif '/resources/trash' in url:
    body = b'{"items":[],"total":0,"page":1,"size":20}'
elif '/00000000-0000-7000-8000-000000000000' in url:
    code = '404'
elif '-X' in args and args[args.index('-X') + 1] == 'DELETE' and '/resources/' in url:
    code = '204'
    (state / 'deleted').write_text('1')
elif '/resources/' in url and (state / 'deleted').exists():
    code = '404'
elif '-H' in args and 'Content-Type: application/json' in args:
    code = '400'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(body)
sys.stdout.write(code)
'''

MVN = r'''#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_STATE}/mvn-args"
case " $* " in *" clean package "*) ;; *) exit 9;; esac
mkdir -p "${PWD}/target"
: > "${PWD}/target/cangshu-0.1.0-SNAPSHOT.jar"
'''

JAVA = '#!/usr/bin/env bash\nif [ "$STUB_SCENARIO" = health_down ]; then exit 0; fi\nexec sleep 120\n'
GIT = '#!/usr/bin/env bash\ncase "$1" in rev-parse) echo stub-commit;; status) :;; esac\n'
CURL = '#!/usr/bin/env bash\nexec python "$STUB_CURL_PY" "$@"\n'
SOCKET = '''import os
class Connected:
    def __enter__(self): return self
    def __exit__(self, *args): return False
def create_connection(*args, **kwargs):
    if os.environ['STUB_SCENARIO'] == 'occupied': return Connected()
    raise ConnectionRefusedError('offline stub: no listener')
'''


def run_case(scenario: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cangshu-demo-stub-") as temp:
        root = Path(temp)
        (root / "scripts").mkdir()
        (root / "bin").mkdir()
        (root / "state").mkdir()
        shutil.copyfile(SOURCE, root / "scripts" / "demo-m1.sh")
        for name, body in {"curl": CURL, "mvn": MVN, "java": JAVA, "git": GIT}.items():
            target = root / "bin" / name
            target.write_text(body, encoding="utf-8", newline="\n")
            target.chmod(0o755)
        (root / "bin" / "curl.py").write_text(CURL_PY, encoding="utf-8", newline="\n")
        (root / "bin" / "socket.py").write_text(SOCKET, encoding="utf-8", newline="\n")
        if scenario == "bad_hash":
            hash_stub = root / "bin" / "sha256sum"
            hash_stub.write_text('#!/usr/bin/env bash\nexit 1\n', encoding="utf-8", newline="\n")
            hash_stub.chmod(0o755)
        (root / "bash-env").write_text('PATH="$STUB_BIN:$PATH"\n', encoding="utf-8", newline="\n")
        env = os.environ.copy()
        env.pop("MVN_CMD", None)
        env.pop("CANGSHU_DEMO_SKIP_BUILD", None)
        root_posix = subprocess.check_output([str(CYGPATH), "-u", str(root)], text=True).strip()
        python_posix = subprocess.check_output([str(CYGPATH), "-u", str(Path(sys.executable).parent)], text=True).strip()
        env.update({"PATH": root_posix + "/bin:" + python_posix + ":/usr/bin:/bin",
                    "STUB_STATE": str(root / "state"), "STUB_SCENARIO": scenario,
                    "BASH_ENV": root_posix + "/bash-env", "STUB_BIN": root_posix + "/bin",
                    "STUB_CURL_PY": root_posix + "/bin/curl.py",
                    "STUB_DATA_ROOT": str(root / "var" / "data"),
                    "PYTHONPATH": str(root / "bin"),
                    "CANGSHU_DEMO_LOG_DIR": root_posix + "/var/demo-logs",
                    "CANGSHU_DEMO_DATA_ROOT": root_posix + "/var/data"})
        if scenario == "data_in_target":
            env["CANGSHU_DEMO_DATA_ROOT"] = root_posix + "/target/custom-data"
        elif scenario == "log_in_target":
            env["CANGSHU_DEMO_LOG_DIR"] = root_posix + "/target/custom-logs"
        elif scenario == "legacy_data":
            legacy = root / "target" / "demo-data-root"
            legacy.mkdir(parents=True)
            (legacy / "keep.txt").write_text("preserve")
        elif scenario == "target_redirect":
            (root / "redirected-target").mkdir()
            (root / "target").symlink_to(root / "redirected-target", target_is_directory=True)
        probe = subprocess.run([str(BASH), "-c", "command -v curl; command -v mvn; command -v java"],
                               cwd=root, env=env, capture_output=True, text=True)
        resolved = probe.stdout.splitlines()
        assert resolved == [root_posix + "/bin/" + name for name in ("curl", "mvn", "java")], resolved
        socket_probe = subprocess.run([sys.executable, "-c", "import socket; print(socket.__file__)"],
                                      env=env, capture_output=True, text=True, check=True)
        assert Path(socket_probe.stdout.strip()).resolve() == (root / "bin" / "socket.py").resolve()
        result = subprocess.run([str(BASH), root_posix + "/scripts/demo-m1.sh"],
                                cwd=root, env=env, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=35)
        expected = scenario == "good"
        summary = root / "var" / "demo-logs" / "demo-summary.txt"
        assert (result.returncode == 0) == expected, (scenario, result.returncode,
                                                        result.stdout[-1200:], result.stderr[-600:],
                                                        summary.read_text(errors="replace")[-1200:] if summary.exists() else "no summary")
        if scenario in ("data_in_target", "log_in_target", "legacy_data", "target_redirect", "occupied"):
            assert not (root / "state" / "mvn-args").exists(), scenario
            if scenario == "legacy_data":
                assert (root / "target" / "demo-data-root" / "keep.txt").read_text() == "preserve"
            print(f"{scenario}: rejected before Maven")
            return
        if scenario != "health_down":
            args = (root / "state" / "mvn-args").read_text()
            assert "clean\npackage\n" in args
            import re
            assert re.search(r"-Dmaven.repo.local=(?:/|[A-Za-z]:[\\/])", args)
            assert (root / "var" / "demo-logs" / "demo-summary.txt").exists()
        print(f"{scenario}: exit={result.returncode}")


if __name__ == "__main__":
    for case in ("good", "missing_id", "bad_dedup", "bad_download", "bad_hash", "health_down", "wrong_root",
                 "data_in_target", "log_in_target", "legacy_data", "target_redirect", "occupied"):
        run_case(case)
