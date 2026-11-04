"""Certificate setup regressions; only disposable fixtures and fake signing tools run."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['SIGNING_CALLS'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
trusted = pathlib.Path(os.environ['SIGNING_TRUSTED'])
if name == 'openssl':
    for flag in ('-out', '-keyout'):
        if flag in args:
            pathlib.Path(args[args.index(flag) + 1]).write_text('disposable fixture bytes')
elif name == 'security':
    if args[0] == 'find-identity':
        if os.environ.get('INITIAL_VALID') == '1' or trusted.exists():
            print('  1) ' + 'A' * 40 + ' "PokeTokenBar Battle Local"')
    elif args[0] == 'find-certificate':
        if os.environ.get('EXISTING_CERT') != '1':
            sys.exit(1)
        print('disposable certificate fixture')
    elif args[0] == 'add-trusted-cert':
        outcome = os.environ.get('TRUST_OUTCOME', 'valid')
        if outcome == 'denied':
            sys.exit(1)
        if outcome == 'valid':
            trusted.touch()
    elif args[0] != 'import':
        sys.exit(90)
else:
    sys.exit(91)
'''


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name)
        self.bin = self.fixture / 'bin'
        self.bin.mkdir()
        for name in ('security', 'openssl'):
            tool = self.bin / name
            tool.write_text(MOCK)
            tool.chmod(0o755)
        source = (ROOT / 'scripts/create-signing-cert.sh').read_text()
        # Production deliberately pins LibreSSL. Redirect that literal only in the
        # disposable script: never execute real openssl or touch a real keychain.
        self.assertEqual(source.count('OPENSSL=/usr/bin/openssl'), 1)
        self.script = self.fixture / 'create-signing-cert.sh'
        self.script.write_text(source.replace('OPENSSL=/usr/bin/openssl',
                                             'OPENSSL="' + str(self.bin / 'openssl') + '"'))
        self.log = self.fixture / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        SIGNING_CALLS=str(self.log),
                        SIGNING_TRUSTED=str(self.fixture / 'trusted'),
                        INITIAL_VALID='0', EXISTING_CERT='0', TRUST_OUTCOME='valid')

    def run_setup(self, **env):
        return subprocess.run(['bash', str(self.script)], env=self.env | env,
                              text=True, capture_output=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_no_regeneration(self):
        self.assertFalse(any(call[0] == 'openssl' or call[:2] == ['security', 'import']
                             for call in self.calls()))

    def assert_failed_without_success(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('완료.', result.stdout)
        self.assertNotIn('다음: ./scripts/build-app.sh', result.stdout)
        self.assertIn('유효', result.stdout + result.stderr)

    def test_new_certificate_denied_trust_fails_without_success(self):
        result = self.run_setup(TRUST_OUTCOME='denied')
        self.assert_failed_without_success(result)
        self.assertTrue(any(call[:2] == ['security', 'import'] for call in self.calls()))

    def test_new_certificate_successful_trust_but_invalid_identity_fails(self):
        self.assert_failed_without_success(self.run_setup(TRUST_OUTCOME='ineffective'))

    def test_new_certificate_valid_identity_succeeds(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('완료.', result.stdout)
        self.assertIn('다음: ./scripts/build-app.sh', result.stdout)

    def test_initially_valid_identity_is_not_regenerated_or_retrusted(self):
        result = self.run_setup(INITIAL_VALID='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_regeneration()
        self.assertEqual(len(self.calls()), 1)

    def test_existing_certificate_retrusts_without_regeneration(self):
        result = self.run_setup(EXISTING_CERT='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_regeneration()
        self.assertTrue(any(call[:2] == ['security', 'add-trusted-cert'] for call in self.calls()))

    def test_existing_certificate_denied_trust_fails_without_regeneration(self):
        result = self.run_setup(EXISTING_CERT='1', TRUST_OUTCOME='denied')
        self.assert_failed_without_success(result)
        self.assert_no_regeneration()

    def test_existing_certificate_ineffective_trust_fails_without_regeneration(self):
        result = self.run_setup(EXISTING_CERT='1', TRUST_OUTCOME='ineffective')
        self.assert_failed_without_success(result)
        self.assert_no_regeneration()


if __name__ == '__main__':
    unittest.main()
