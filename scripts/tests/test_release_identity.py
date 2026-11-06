"""The release commit goes straight to public main, so its git identity must already be public.

These run real git in disposable repositories. The stubbed release tests cannot see an identity at all,
which is how a clone without a repository identity could commit under the machine's global one.
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALIDATE = ROOT / 'scripts/release-validate.py'
FORK = ('fork-owner', 'fork-owner@example.test')
UPSTREAM = ('upstream-author', 'upstream-author@example.test')
MACHINE = ('Machine Global Name', 'machine-global@corp.example')
NOREPLY = 'fork-owner@users.noreply.github.com'


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.global_config = self.base / 'global-gitconfig'
        self.write_global(MACHINE)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(GIT_CONFIG_GLOBAL=str(self.global_config), GIT_CONFIG_NOSYSTEM='1', HOME=str(self.base))
        self.origin = self.base / 'origin'
        self.origin.mkdir()
        self.git(self.origin, 'init', '-q', '-b', 'main')
        self.commit_as(UPSTREAM, 'upstream work')
        self.git(self.origin, 'tag', 'v2.5.6')
        self.commit_as(FORK, 'fork work')

    def write_global(self, identity):
        self.global_config.write_text(f'[user]\n\tname = {identity[0]}\n\temail = {identity[1]}\n')

    def git(self, cwd, *args):
        return subprocess.run(['git', *args], cwd=cwd, env=self.env, check=True, capture_output=True, text=True).stdout

    def commit_as(self, identity, message):
        self.git(self.origin, '-c', f'user.name={identity[0]}', '-c', f'user.email={identity[1]}',
                 'commit', '-q', '--allow-empty', '-m', message)

    def clone(self):
        target = self.base / 'clone'
        self.git(self.base, 'clone', '-q', str(self.origin), str(target))
        return target

    def check(self, repo, **env):
        return subprocess.run([sys.executable, str(VALIDATE), 'commit-identity', str(repo)],
                              env={**self.env, **env}, capture_output=True, text=True)

    def assertRefused(self, result):
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        # A usage error also exits non-zero, so the refusal has to be the identity check speaking.
        self.assertIn('Release validation: Release commit identity', result.stderr)

    def test_fresh_clone_falling_back_to_the_global_identity_is_refused(self):
        self.assertRefused(self.check(self.clone()))

    def test_refusal_does_not_print_the_identity(self):
        result = self.check(self.clone())
        for value in MACHINE:
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_repository_identity_from_the_fork_history_passes(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', FORK[1])
        result = self.check(repo)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_known_email_with_the_global_name_is_refused(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.email', FORK[1])
        self.assertRefused(self.check(repo))

    def test_known_name_with_the_global_email_is_refused(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.assertRefused(self.check(repo))

    def test_github_noreply_with_a_known_name_passes_before_it_appears_in_history(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', NOREPLY)
        result = self.check(repo)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_github_noreply_with_an_unknown_name_is_refused(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', MACHINE[0])
        self.git(repo, 'config', 'user.email', NOREPLY)
        self.assertRefused(self.check(repo))

    def test_an_address_that_only_looks_like_noreply_is_refused(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', 'x@users.noreply.github.com.corp.example')
        self.assertRefused(self.check(repo))

    def test_an_identity_only_in_upstream_history_is_refused(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', UPSTREAM[0])
        self.git(repo, 'config', 'user.email', UPSTREAM[1])
        self.assertRefused(self.check(repo))

    def test_committer_override_is_checked_on_its_own(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', FORK[1])
        self.assertRefused(self.check(repo, GIT_COMMITTER_NAME=MACHINE[0], GIT_COMMITTER_EMAIL=MACHINE[1]))

    def test_author_override_is_checked_on_its_own(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', FORK[1])
        self.assertRefused(self.check(repo, GIT_AUTHOR_NAME=MACHINE[0], GIT_AUTHOR_EMAIL=MACHINE[1]))

    def test_missing_baseline_tag_fails_closed(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', FORK[1])
        self.git(repo, 'tag', '-d', 'v2.5.6')
        self.assertRefused(self.check(repo))

    def test_no_fork_commits_after_the_baseline_fails_closed(self):
        repo = self.clone()
        self.git(repo, 'config', 'user.name', FORK[0])
        self.git(repo, 'config', 'user.email', FORK[1])
        self.git(repo, 'reset', '-q', '--hard', 'v2.5.6')
        self.assertRefused(self.check(repo))


if __name__ == '__main__':
    unittest.main()
