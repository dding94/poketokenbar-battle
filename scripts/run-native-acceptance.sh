#!/bin/bash
# Synthetic, local-only native HTTP/WS/JSC acceptance. No install, deployment, or account lookup.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
exec python3 - "$repo" "$@" <<'PY'
import json, os, pathlib, re, shutil, signal, socket, subprocess, sys, tempfile, time, urllib.request
repo = pathlib.Path(sys.argv[1])
wrapped_command = sys.argv[3:] if len(sys.argv) > 2 and sys.argv[2] == '--' else []
if len(sys.argv) > 2 and not wrapped_command:
    raise SystemExit('usage: scripts/run-native-acceptance.sh [-- command args...]')
node = shutil.which('node')
wrangler = repo / 'server/node_modules/wrangler/bin/wrangler.js'
if not node or not wrangler.exists() or not (repo / 'engine/dist/battle-engine.js').exists():
    raise SystemExit('Install server dependencies with npm ci and build the engine before running acceptance.')
worker = None
swift = None

def stop(process):
    if process is None:
        return
    # Every child has its own process group. Never discover/terminate a user's app or other Worker.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()

def interrupted(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGHUP, interrupted)
signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
with tempfile.TemporaryDirectory(prefix='ptb-native-acceptance-') as temporary:
    runtime = pathlib.Path(temporary)
    for name in ['config', 'worker-state', 'ptb', 'clang']:
        (runtime / name).mkdir()
    # Bind distinct ephemeral ports together before releasing them for Wrangler. A competing bind
    # fails startup; it never falls back to contacting another service or killing its owner.
    with socket.socket() as http, socket.socket() as inspector:
        http.bind(('127.0.0.1', 0)); inspector.bind(('127.0.0.1', 0))
        port, inspector_port = http.getsockname()[1], inspector.getsockname()[1]
    synthetic_secret = 'synthetic-native-acceptance-operator-only-00000000'
    config = {'name': 'ptb-native-acceptance-only', 'main': str(repo / 'server/src/index.ts'),
        'compatibility_date': '2026-08-01', 'workers_dev': False,
        'durable_objects': {'bindings': [{'name': 'LEAGUE', 'class_name': 'League'}]},
        'migrations': [{'tag': 'v1', 'new_sqlite_classes': ['League']}],
        'observability': {'enabled': False, 'logs': {'enabled': False}},
        'vars': {'CODE_PEPPER': 'synthetic-native-acceptance-pepper', 'OPERATOR_SECRET': synthetic_secret}}
    (runtime / 'wrangler.json').write_text(json.dumps(config))
    (runtime / 'empty.env').write_text('')
    worker_env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'XDG_CONFIG_HOME': str(runtime / 'config'),
        'WRANGLER_SEND_METRICS': 'false', 'CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV': 'false',
        'CLOUDFLARE_INCLUDE_PROCESS_ENV': 'false'}
    url = f'http://127.0.0.1:{port}'
    try:
        with (runtime / 'worker.log').open('w') as worker_log:
            worker = subprocess.Popen([node, str(wrangler), 'dev', '--config', str(runtime / 'wrangler.json'),
                '--env-file', str(runtime / 'empty.env'), '--local', '--ip', '127.0.0.1', '--port', str(port),
                '--inspector-port', str(inspector_port), '--persist-to', str(runtime / 'worker-state'),
                '--log-level', 'error'], cwd=runtime, env=worker_env, stdout=worker_log,
                stderr=subprocess.STDOUT, start_new_session=True)
            for attempt in range(200):
                if worker.poll() is not None:
                    raise RuntimeError('Local Worker exited before readiness (no credentials or logs printed).')
                try:
                    # Do not route localhost through a user's configured HTTP proxy.
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open(url + '/v1/health', timeout=.5) as response:
                        if response.status == 200:
                            break
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('Local Worker did not become ready.')
            env = dict(os.environ, PTB_NATIVE_ACCEPTANCE_URL=url, PTB_NATIVE_OPERATOR_SECRET=synthetic_secret,
                PTB_STATE_DIR=str(runtime / 'ptb'), CLANG_MODULE_CACHE_PATH=str(runtime / 'clang'))
            command = wrapped_command or ['swift', 'test', '--disable-sandbox', '--scratch-path',
                os.environ.get('PTB_NATIVE_SCRATCH_PATH', str(runtime / 'swift-build')),
                '--jobs', '2', '--filter', 'OnlineBattleNativeAcceptanceTests']
            with (runtime / 'swift.log').open('w') as log:
                swift = subprocess.Popen(command, cwd=repo, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, start_new_session=True)
                for line in swift.stdout:
                    print(line, end='', flush=True); log.write(line)
                result = swift.wait()
            if result:
                raise SystemExit(result)
            transcript = (runtime / 'swift.log').read_text()
            expected = ['testNativeManualAndAutomaticReportsPrivacyReplayAndRematch',
                'testSessionsRecoverCommittedResponseLossAndApplyDurablyOnce',
                'testSessionsReleaseVoidWithoutHealthXPWalletOrUsageEffects']
            for name in expected:
                if not re.search(r"Test Case '-\[PokeTokenBarTests.OnlineBattleNativeAcceptanceTests " + name + r"\]' passed", transcript):
                    raise RuntimeError('Required native acceptance test did not pass: ' + name)
            if re.search(r"Test Case .*OnlineBattleNativeAcceptanceTests .* skipped", transcript):
                raise RuntimeError('Native acceptance unexpectedly skipped a test.')
            print(f'NATIVE_ACCEPTANCE required={len(expected)} passed={len(expected)} skipped=0 (single Mac, local Worker)')
    finally:
        stop(swift)
        stop(worker)
PY
