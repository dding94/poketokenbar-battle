"""T08: the server address is injected at build time and must never be committed. Fixtures use example.test only."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALIDATE = ROOT / 'scripts/release-validate.py'
# Assembled at runtime so this file itself never looks like a committed address to the scan.
ACCOUNT, SUFFIX = 'some-account', '.workers' + '.dev'


def validate(*args, cwd=None):
    return subprocess.run(['python3', str(VALIDATE), *args], capture_output=True, text=True, cwd=cwd)


class ServerUrlNormalizationTests(unittest.TestCase):
    def test_accepts_https_origins_and_prints_the_normalized_form(self):
        for value, expected in (('https://example.test', 'https://example.test'),
                                ('https://example.test/', 'https://example.test'),
                                ('HTTPS://Example.TEST:443/', 'https://example.test'),
                                ('https://api.example.test:8443', 'https://api.example.test:8443')):
            with self.subTest(value=value):
                result = validate('server-url', value)
                self.assertEqual((result.returncode, result.stdout.strip()), (0, expected), result.stderr)

    def test_rejects_anything_that_is_not_a_plain_https_origin(self):
        for value in ('', ' ', 'example.test', 'http://example.test', 'ftp://example.test', 'https://', 'https://example.test/path',
                      'https://example.test?x=1', 'https://example.test#frag', 'https://user@example.test',
                      'https://user:pw@example.test', 'https://example.test:0', 'https://example.test:99999',
                      'https://exa mple.test', 'https://example.test/\n', 'https://[::1]', '$(PTB_BATTLE_SERVER_URL)',
                      'https://example.test"><x/>'):
            with self.subTest(value=value):
                result = validate('server-url', value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Server URL', result.stderr)
                self.assertEqual(result.stdout, '')


class CommittedAddressScanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        (self.repo / 'scripts').mkdir()
        shutil.copy(VALIDATE, self.repo / 'scripts/release-validate.py')

    def scan(self):
        return validate('addresses', str(self.repo))

    def test_passes_for_placeholders_and_prose(self):
        (self.repo / 'a.md').write_text('Use https://example.test or ptb-battle-league-dev.example.workers.dev; '
                                        'ptb-battle-league-dev.<subdomain>.workers.dev and the workers.dev subdomain are fine.\n')
        (self.repo / 'b.ts').write_text('const x = "https://ptb-battle-league-dev.secret-sub.workers.dev";\n')
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_a_real_looking_workers_dev_address_in_any_text_file(self):
        for name in ('notes.md', 'Sources/App.swift', 'server/wrangler.jsonc', 'scripts/x.sh'):
            with self.subTest(name=name):
                path = self.repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('url = https://ptb-battle-league.' + ACCOUNT + SUFFIX + '/v1\n')
                result = self.scan()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertNotIn(ACCOUNT, result.stderr, 'the offending address must not be echoed')
                path.unlink()

    def test_ignores_generated_dependency_directories(self):
        for directory in ('node_modules', '.build', 'build', '.git'):
            path = self.repo / directory / 'x.txt'
            path.parent.mkdir()
            path.write_text('https://w.' + ACCOUNT + SUFFIX + '\n')
        self.assertEqual(self.scan().returncode, 0)

    def test_release_source_check_runs_the_scan(self):
        core = self.repo / 'Sources/PokeTokenBar/Core'
        core.mkdir(parents=True)
        for name in ('AppIdentity.swift', 'UpdateChecker.swift'):
            shutil.copy(ROOT / 'Sources/PokeTokenBar/Core' / name, core / name)
        for name in ('build-app.sh', 'battle.entitlements'):
            shutil.copy(ROOT / 'scripts' / name, self.repo / 'scripts' / name)
        baseline = validate('source', str(self.repo))
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        (self.repo / 'leak.md').write_text('https://w.' + ACCOUNT + SUFFIX + '\n')
        leaked = validate('source', str(self.repo))
        self.assertNotEqual(leaked.returncode, 0)
        self.assertIn('leak.md', leaked.stderr)

    def test_the_real_repository_is_clean(self):
        result = validate('addresses', str(ROOT))
        self.assertEqual(result.returncode, 0, result.stderr)


class BuildScriptAddressTests(unittest.TestCase):
    def run_build(self, value):
        env = {k: v for k, v in os.environ.items() if not k.startswith('PTB_')}
        env.update(PTB_SKIP_INSTALL='1', PTB_NATIVE_ARCH_ONLY='1', PTB_BATTLE_SERVER_URL=value)
        # A bad value must stop before any compile; the empty PATH-less swift stub proves nothing was started.
        with tempfile.TemporaryDirectory() as bin_dir:
            stub = Path(bin_dir) / 'swift'
            stub.write_text('#!/bin/sh\necho swift-was-started >&2\nexit 77\n')
            stub.chmod(0o755)
            env['PATH'] = bin_dir + os.pathsep + env['PATH']
            return subprocess.run(['bash', str(ROOT / 'scripts/build-app.sh')], capture_output=True, text=True, env=env)

    def test_invalid_address_fails_the_build_before_compiling(self):
        for value in ('http://example.test', 'https://example.test/path', 'nonsense'):
            with self.subTest(value=value):
                result = self.run_build(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Server URL', result.stderr)
                self.assertNotIn('swift-was-started', result.stderr)

    def test_build_script_writes_the_info_plist_key_and_never_a_literal_address(self):
        script = (ROOT / 'scripts/build-app.sh').read_text()
        self.assertIn('PTBBattleServerURL', script)
        self.assertIn('PTB_BATTLE_SERVER_URL', script)
        self.assertNotIn('workers.dev', script)


if __name__ == '__main__':
    unittest.main()
