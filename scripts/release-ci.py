#!/usr/bin/env python3
"""Require read-only, exact-HEAD GitHub CI evidence before a local release build.

GitHub's attempt-specific job API binds log job IDs to the selected run attempt:
https://docs.github.com/en/rest/actions/workflow-jobs
No token is read or printed by this script; gh performs its existing authentication.
"""
import json
import re
import subprocess
import sys

REPO = 'dding94/poketokenbar-battle'
WORKFLOW = '.github/workflows/ci.yml'
# Match the complete CI contract, not only overall run success or a partial dispatch.
REQUIRED = {
    'changes': (),
    'build-test (rendering)': ('Isolate test state and render output', 'Rendering tests', 'List every test',
                               'Prove the fork identity guard rejects an upstream value'),
    'build-test (rest)': ('Isolate test state and render output',
                          'Install isolated native acceptance server dependencies', 'Test + coverage gate'),
    'test-union': ('Every test ran exactly once',),
    'secret-scan': ('Scan for committed secrets',),
    'server': ('Install pinned dependencies', 'Typecheck', 'Worker and League tests in workerd'),
    'determinism (macos-15)': ('Isolate test state', 'Swift JavaScriptCore boundary',
                              'Install pinned dependencies', 'Engine contracts and deterministic corpus'),
    'determinism (macos-26)': ('Isolate test state', 'Swift JavaScriptCore boundary',
                              'Install pinned dependencies', 'Engine contracts and deterministic corpus'),
}
NATIVE_TESTS = (
    'testNativeManualAndAutomaticReportsPrivacyReplayAndRematch',
    'testSessionsRecoverCommittedResponseLossAndApplyDurablyOnce',
    'testSessionsReleaseVoidWithoutHealthXPWalletOrUsageEffects',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    # Keep API errors/logs private: a failure reports the command, never captured output.
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60).stdout


def api(endpoint):
    # All endpoints are constructed here; no caller-supplied URL, method, token, or response file.
    return command('gh', 'api', f'repos/{REPO}/{endpoint}', '--hostname', 'github.com')


def clean_head():
    require(not command('git', 'status', '--porcelain', '--untracked-files=no').strip(),
            'Tracked worktree changes are not covered by HEAD CI')
    # Untracked source can be compiled by SwiftPM despite a clean tracked tree. Generated build
    # outputs are ignored by Git; ordinary untracked logs elsewhere need not block preparation.
    untracked = command('git', 'ls-files', '--others', '--exclude-standard', '--',
                        'Sources', 'Tests', 'scripts', 'server', 'engine', 'Package.swift',
                        'Package.resolved', '.github/workflows').splitlines()
    require(not any(path and not (path.endswith('.log') or ('/__pycache__/' in path and path.endswith(('.pyc', '.pyo'))))
                    for path in untracked),
            'Untracked build/test inputs are not covered by HEAD CI')
    head = command('git', 'rev-parse', 'HEAD').strip()
    require(re.fullmatch(r'[0-9a-f]{40}', head), 'Cannot determine the exact source HEAD')
    return head


def successful(value):
    return value.get('status') == 'completed' and value.get('conclusion') == 'success'


def verify(run_id):
    require(re.fullmatch(r'[1-9][0-9]*', run_id), 'PTB_CI_RUN_ID must select an existing numeric GitHub CI run')
    head = clean_head()
    run = json.loads(api(f'actions/runs/{run_id}'))
    require(run.get('id') == int(run_id), 'CI run identity mismatch')
    require(run.get('head_sha') == head, 'Selected CI run does not cover exact HEAD')
    require(run.get('repository', {}).get('full_name') == REPO and
            run.get('head_repository', {}).get('full_name') == REPO, 'CI run must belong to the fork repository')
    require(run.get('name') == 'CI' and run.get('path', '').split('@', 1)[0] == WORKFLOW,
            'Selected run is not the fork CI workflow')
    require(successful(run), 'Selected CI run is not completed successfully')
    attempt = run.get('run_attempt')
    require(type(attempt) is int and attempt > 0, 'Missing CI run attempt')
    response = json.loads(api(f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100'))
    jobs = response.get('jobs', [])
    require(response.get('total_count') == len(jobs) and 0 < len(jobs) <= 100,
            'Incomplete CI job listing; refuse missing/paginated evidence')
    by_name = {}
    for job in jobs:
        require(job.get('run_id') == int(run_id) and job.get('head_sha') == head,
                'CI job does not belong to the selected run/HEAD')
        # The endpoint fixes the attempt. Reject a contradictory field if an API version supplies it.
        require(job.get('run_attempt', attempt) == attempt, 'CI job run attempt mismatch')
        name = job.get('name')
        require(name not in by_name, 'Ambiguous duplicate CI job name')
        by_name[name] = job
    for name, steps in REQUIRED.items():
        job = by_name.get(name, {})
        require(successful(job), f'Required CI job missing, skipped, or failed: {name}')
        for step_name in steps:
            found = [step for step in job.get('steps', []) if step.get('name') == step_name]
            require(len(found) == 1 and successful(found[0]), f'Required CI step missing, skipped, or failed: {step_name}')
    rest_id = by_name['build-test (rest)'].get('id')
    require(type(rest_id) is int and rest_id > 0, 'Missing rest job log identity')
    log = api(f'actions/jobs/{rest_id}/logs')
    require('NATIVE_ACCEPTANCE required=3 passed=3 skipped=0' in log,
            'CI native acceptance requires three actual passes and zero native skips')
    for test in NATIVE_TESTS:
        label = re.escape("Test Case '-[PokeTokenBarTests.OnlineBattleNativeAcceptanceTests " + test + "]'")
        require(re.search(label + r' passed\b', log), f'Native acceptance pass missing: {test}')
        require(not re.search(label + r' (?:skipped|failed)\b', log), f'Native acceptance did not pass: {test}')
    # Reject a rerun/changed source while evidence was being read; no local test is substituted.
    latest = json.loads(api(f'actions/runs/{run_id}'))
    require(all(latest.get(key) == run.get(key) for key in
                ('id', 'head_sha', 'run_attempt', 'status', 'conclusion')), 'CI run changed while reading evidence')
    require(clean_head() == head, 'Source HEAD changed while reading CI evidence')
    print(f'Verified CI run {run_id}, attempt {attempt}, HEAD {head}: eight required jobs and three native acceptance passes. Existing opt-in skips remain unverified.')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2, 'Use release-ci.py PTB_CI_RUN_ID')
        verify(sys.argv[1])
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f'Release CI: {error}')
