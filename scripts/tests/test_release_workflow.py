"""Release boundary regressions. Commands run only in disposable fixture repositories."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEAF = hashlib.sha1(b'public certificate fixture').hexdigest().upper()
NOTES = '''## New
None.
## Fixed
None.
## Other
Release preparation.
## Contributors
No external contributors in this release.
---
**Install:** Download `PokeTokenBarBattle.zip` from this fork's release and move `PokeTokenBar Battle.app` to `/Applications`.
**Upgrade:** Replace only `/Applications/PokeTokenBar Battle.app` after backing up `PokeTokenBarBattle` state. Homebrew is not available until the fork tap is published.
'''
MOCK = r'''#!/usr/bin/env python3
import os, sys, pathlib, plistlib, base64, json
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f: f.write(name+' '+ ' '.join(args)+'\n')
if name=='git':
    if args[:2]==['remote','get-url']: print(os.environ.get('ORIGIN','https://github.com/dding94/poketokenbar-battle.git'))
    elif args[:1]==['describe']: print('v2.5.6')
    elif args[:1]==['diff']: print('Sources/PokeTokenBar/UI/New.swift' if (os.environ.get('DOC_FAIL') or os.environ.get('DOC_WARNING')) and 'Sources/PokeTokenBar/UI/' in args else '')
    elif args[:1]==['log']: print('feat: battle screen' if os.environ.get('DOC_FAIL') else '')
    elif args[:1]==['rev-parse']: print(os.environ.get('BRANCH','feat/release-fixture') if '--abbrev-ref' in args else '1'*40)
    elif args[:1]==['status']: print(' M source.swift' if os.environ.get('DIRTY') else '')
    elif args[:1]==['ls-files']: print(os.environ.get('UNTRACKED_SOURCE','') or ('Sources/New.swift' if pathlib.Path('Sources/New.swift').exists() else ''))
    elif args[:1] and args[0] in ('add','commit','push') and os.environ.get('ALLOW_PUBLICATION_STUB'): pass
    else: sys.exit(90)
elif name=='security': print('  1) '+os.environ.get('ACTUAL_LEAF',os.environ['PTB_EXPECTED_LEAF'])+' "PokeTokenBar Battle Local"')
elif name=='lipo':
    if os.environ.get('BAD_ARCH') and args[-1]=='x86_64': sys.exit(1)
elif name=='otool':
    print(os.environ.get('OTOOL_OUTPUT', 'Load command 0\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform 1\n    minos '+os.environ.get('MINOS','15.0')+'\n      sdk 27.0\n   ntools 1\n     tool 3\n  version 27106.1\nLoad command 1\n      cmd LC_LOAD_DYLIB\n  cmdsize 56\n current version 1234.5.6'))
elif name=='codesign':
    if '--extract-certificates' in args:
        # codesign's optional prefix must be attached with '='. A split prefix
        # is interpreted as another target, not an option argument.
        print('split certificate prefix interpreted as target', file=sys.stderr)
        sys.exit(95)
    extraction = [arg for arg in args if arg.startswith('--extract-certificates=')]
    if extraction:
        if len(extraction) != 1 or len(args) != 3 or args[0] != '-d' or args[1] != extraction[0]: sys.exit(96)
        prefix = extraction[0].split('=', 1)[1]
        if not prefix or not pathlib.Path(args[2]).is_dir(): sys.exit(97)
        pathlib.Path(prefix+'0').write_bytes(b'wrong certificate' if os.environ.get('BAD_CERT') else b'public certificate fixture')
    elif '--entitlements' in args: print(plistlib.dumps({'com.apple.security.cs.allow-jit':not bool(os.environ.get('BAD_JIT'))}).decode())
    elif '--verify' in args and os.environ.get('BAD_SIGN'): sys.exit(1)
elif name=='ditto': pathlib.Path(args[-1]).write_bytes(b'fixture zip bytes')
elif name=='gh':
    if args[:1]==['api'] and '/actions/' in args[1]:
        if os.environ.get('API_UNAVAILABLE'): sys.exit(93)
        if '/jobs/' in args[1] and args[1].endswith('/logs'): key='CI_LOG_FILE'
        elif '/jobs?' in args[1]: key='CI_JOBS_FILE'
        else: key='CI_RUN_FILE'
        if key=='CI_LOG_FILE' and '\x1b' in pathlib.Path(os.environ[key]).read_text() and '--allow-escape-sequences' not in args: sys.exit(94)
        print(pathlib.Path(os.environ[key]).read_text())
    elif args[:2]==['api','repos/dding94/homebrew-tap/contents/Casks/poke-token-bar-battle.rb']:
        path=os.environ.get('FAKE_TAP')
        print(json.dumps({'sha':'existing-file-sha','content':base64.b64encode(pathlib.Path(path).read_bytes()).decode()}) if path else '{}')
    elif args[:1]==['release'] or '-X' in args:
        if '--input' in args:
            pathlib.Path(os.environ['CALLS']+'.update.json').write_bytes(pathlib.Path(args[args.index('--input')+1]).read_bytes())
        print('fixture published')
    else: sys.exit(91)
else: sys.exit(92)
'''

class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for directory in ('scripts', 'Sources/PokeTokenBar/Core', 'engine/dist', 'engine/archive'):
            (self.repo / directory).mkdir(parents=True, exist_ok=True)
        for name in ('release.sh', 'release-metadata.py', 'release-validate.py', 'release-ci.py', 'package-battle-engines.sh'):
            source = ROOT / 'scripts' / name
            if source.exists(): shutil.copy(source, self.repo / 'scripts' / name)
        for name in ('AppIdentity.swift','UpdateChecker.swift','BattleEngineManifest.swift','BattleEngineArchive.swift'):
            shutil.copy(ROOT / 'Sources/PokeTokenBar/Core' / name, self.repo / 'Sources/PokeTokenBar/Core' / name)
        shutil.copy(ROOT / 'engine/dist/battle-engine.js', self.repo / 'engine/dist/battle-engine.js')
        for source in (ROOT / 'engine/archive').glob('*.js'): shutil.copy(source,self.repo / 'engine/archive' / source.name)
        (self.repo / 'scripts/build-app.sh').write_text((ROOT / 'scripts/build-app.sh').read_text())
        (self.repo / 'scripts/battle.entitlements').write_text((ROOT / 'scripts/battle.entitlements').read_text())
        (self.repo / 'README.md').write_text('Fork release preparation.\n')
        (self.repo / 'notes.md').write_text(NOTES)
        (self.repo / 'contributors.txt').write_text('')
        self.bin = self.repo / 'bin'; self.bin.mkdir()
        for name in ('git','gh','security','lipo','codesign','ditto','otool','pkill'):
            file=self.bin / name; file.write_text(MOCK); file.chmod(0o755)
        self.env={k:v for k,v in os.environ.items() if not k.startswith(('PTB_', 'CODESIGN_'))}
        self.env.update(PATH=str(self.bin)+os.pathsep+self.env['PATH'], CALLS=str(self.repo/'calls'),
                        PTB_EXPECTED_LEAF=LEAF, PTB_NOTES_FILE=str(self.repo/'notes.md'),
                        PTB_CONTRIBUTORS_FILE=str(self.repo/'contributors.txt'))
        self.ci_run={'id':12345,'head_sha':'1'*40,'name':'CI','path':'.github/workflows/ci.yml',
                     'status':'completed','conclusion':'success','run_attempt':1,
                     'repository':{'full_name':'dding94/poketokenbar-battle'},
                     'head_repository':{'full_name':'dding94/poketokenbar-battle'}}
        required={
            'changes':[],
            'build-test (rendering)':['Isolate test state and render output','Rendering tests','List every test','Prove the fork identity guard rejects an upstream value'],
            'build-test (rest)':['Isolate test state and render output','Install isolated native acceptance server dependencies','Test + coverage gate'],
            'test-union':['Every test ran exactly once'],
            'secret-scan':['Scan for committed secrets'],
            'server':['Install pinned dependencies','Typecheck','Worker and League tests in workerd'],
            'determinism (macos-15)':['Isolate test state','Swift JavaScriptCore boundary','Install pinned dependencies','Engine contracts and deterministic corpus'],
            'determinism (macos-26)':['Isolate test state','Swift JavaScriptCore boundary','Install pinned dependencies','Engine contracts and deterministic corpus']}
        self.ci_jobs={'total_count':len(required),'jobs':[
            {'id':100+index,'name':name,'status':'completed','conclusion':'success',
             'run_id':12345,'run_attempt':1,'head_sha':'1'*40,
             'steps':[{'name':step,'status':'completed','conclusion':'success'} for step in steps]}
            for index,(name,steps) in enumerate(required.items())]}
        self.ci_log='\n'.join("Test Case '-[PokeTokenBarTests.OnlineBattleNativeAcceptanceTests "+name+"]' passed (1.0 seconds)." for name in (
            'testNativeManualAndAutomaticReportsPrivacyReplayAndRematch',
            'testSessionsRecoverCommittedResponseLossAndApplyDurablyOnce',
            'testSessionsReleaseVoidWithoutHealthXPWalletOrUsageEffects'))+'\nNATIVE_ACCEPTANCE required=3 passed=3 skipped=0 (single Mac, local Worker)\n'
        self.write_ci_fixture()
        self.env['PTB_CI_RUN_ID']='12345'

    def write_ci_fixture(self):
        for name,value in (('run',self.ci_run),('jobs',self.ci_jobs),('log',self.ci_log)):
            path=self.repo/('ci-'+name+'.json')
            path.write_text(value if isinstance(value,str) else json.dumps(value))
            self.env['CI_'+name.upper()+'_FILE']=str(path)

    def run_release(self,*args,**env):
        return subprocess.run(['bash',str(self.repo/'scripts/release.sh'),*args],env=self.env|env,
                              text=True,capture_output=True)

    def calls(self):
        return (self.repo/'calls').read_text() if (self.repo/'calls').exists() else ''

    def fake_build(self):
        # Keep identity/version literals for source preflight; replace execution body.
        original=(ROOT/'scripts/build-app.sh').read_text()
        header=original[:original.index('# 원본 설치본')] + '# installation path: \"/Applications/$APP_NAME.app\"\n'
        body='''
[[ "$PTB_SKIP_INSTALL" == 1 && "$PTB_REQUIRE_STABLE_SIGN" == 1 && "$PTB_NATIVE_ARCH_ONLY" == 0 ]] || exit 88
printf 'build:skip-install=%s version=%s\\n' "$PTB_SKIP_INSTALL" "$PTB_RELEASE_VERSION" >> "$CALLS"
python3 - <<'BUILD'
import os, pathlib, plistlib
app=pathlib.Path('build/PokeTokenBar Battle.app/Contents')
(app/'MacOS').mkdir(parents=True,exist_ok=True)
(app/'MacOS/PokeTokenBarBattle').write_text('fixture binary')
plist={'CFBundleIdentifier':'io.github.dding94.poketokenbar-battle','CFBundleName':'PokeTokenBar Battle', 'CFBundleExecutable':'PokeTokenBarBattle','CFBundleShortVersionString':os.environ['PTB_RELEASE_VERSION'],'LSMinimumSystemVersion':'15.0'}
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
(app/'Resources').mkdir(exist_ok=True)
(app/'Library/LaunchAgents').mkdir(parents=True,exist_ok=True)
(app/'Library/LaunchAgents/io.github.dding94.poketokenbar-battle.login.plist').write_bytes(plistlib.dumps({'Label':'io.github.dding94.poketokenbar-battle.login','ProgramArguments':['/Applications/PokeTokenBar Battle.app/Contents/MacOS/PokeTokenBarBattle']}))
BUILD
bash scripts/package-battle-engines.sh "build/PokeTokenBar Battle.app/Contents/Resources"
[[ "${CORRUPT_ENGINE:-0}" != 1 ]] || printf corrupt > "build/PokeTokenBar Battle.app/Contents/Resources/battle-engine.js"
'''
        path=self.repo/'scripts/build-app.sh';path.write_text(header+body);path.chmod(0o755)
        (self.repo/'engine/LICENSE.pokemon-showdown').write_text('fixture license')
        gate=self.repo/'scripts/test-gate.sh';gate.write_text('#!/bin/sh\nprintf \"local-test-gate state=%s\\n\" \"${PTB_STATE_DIR:-UNISOLATED}\" >> \"$CALLS\"\nexit 0\n');gate.chmod(0o755)

    def test_check_only_propagates_hard_asset_failure(self):
        result=self.run_release('--check-only',DOC_FAIL='1')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('security ',self.calls())

    def test_check_only_propagates_document_warning(self):
        result=self.run_release('--check-only',DOC_WARNING='1')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertNotIn('security ',self.calls())

    def test_check_only_rejects_upstream_origin(self):
        result=self.run_release('--check-only',ORIGIN='https://github.com/chattymin/PokeTokenBar.git')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('origin',result.stderr)

    def test_prepare_feature_branch_no_credentials_and_no_mutations(self):
        before=(self.repo/'scripts/build-app.sh').read_bytes()
        self.env.pop('PTB_EXPECTED_LEAF')
        result=self.run_release('--prepare','3.0.0')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,(self.repo/'scripts/build-app.sh').read_bytes())
        self.assertNotRegex(self.calls(),r'(?m)^(security|codesign|gh|ditto|pkill) |^git (add|commit|push|tag) ')
        self.assertIn('NOT verified',result.stdout)

    def test_prepare_rejects_upstream_notes(self):
        (self.repo/'notes.md').write_text(NOTES.replace('PokeTokenBarBattle.zip','PokeTokenBar.zip'))
        result=self.run_release('--prepare','3.0.0')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('PokeTokenBarBattle.zip',result.stderr)

    def test_prepare_build_requires_explicit_stable_leaf_before_build(self):
        self.env.pop('PTB_EXPECTED_LEAF')
        result=self.run_release('--prepare-build','3.0.0')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('PTB_EXPECTED_LEAF',result.stderr)
        self.assertNotIn('build:',self.calls())

    def test_prepare_build_creates_valid_preview_without_tracked_bump_or_publish(self):
        self.fake_build();before=(self.repo/'scripts/build-app.sh').read_bytes()
        result=self.run_release('--prepare-build','3.0.0')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,(self.repo/'scripts/build-app.sh').read_bytes())
        cask=(self.repo/'build/release/poke-token-bar-battle.rb').read_text()
        self.assertIn(hashlib.sha256(b'fixture zip bytes').hexdigest(),cask)
        self.assertIn('https://github.com/dding94/poketokenbar-battle/releases/download/v#{version}/PokeTokenBarBattle.zip',cask)
        self.assertIn('depends_on macos: ">= :sequoia"',cask)
        self.assertIn('app "PokeTokenBar Battle.app"',cask)
        self.assertIn('build:skip-install=1 version=3.0.0',self.calls())
        self.assertNotRegex(self.calls(),r'(?m)^gh release |^gh api -X |^pkill |^git (add|commit|push|tag) ')

    def test_source_added_during_build_rejects_artifact_before_packaging(self):
        self.fake_build()
        build = self.repo / 'scripts/build-app.sh'
        build.write_text(build.read_text() + '\nprintf "// newly compiled source\\n" > Sources/New.swift\n')
        result = self.run_release('--prepare-build', '3.0.0')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('build:skip-install=1', self.calls())
        self.assertIn('Untracked build/test inputs', result.stderr)
        self.assertNotIn('ditto ', self.calls())
        self.assertFalse((self.repo / 'build/release/poke-token-bar-battle.rb').exists())

    def test_colored_ci_logs_are_captured_and_normalized_without_terminal_output(self):
        self.fake_build()
        self.ci_log = self.ci_log.replace(' passed ', ' \x1b[32mpassed\x1b[0m ')
        self.write_ci_fixture()
        result = self.run_release('--prepare-build', '3.0.0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('\x1b', result.stdout + result.stderr)
        self.assertIn('--allow-escape-sequences', self.calls())

    def test_leaf_mismatch_stops_without_prompt_or_build(self):
        self.fake_build()
        result=self.run_release('--prepare-build','3.0.0',ACTUAL_LEAF='F'*40)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('build:',self.calls())

    def test_invalid_bundle_prevents_zip_preview(self):
        for injection, expected in (({'BAD_ARCH':'1'}, 'lipo'), ({'MINOS':'14.0'}, 'deployment target'),
                                    ({'BAD_JIT':'1'}, 'JIT'), ({'BAD_SIGN':'1'}, 'codesign'),
                                    ({'BAD_CERT':'1'}, 'certificate leaf'), ({'CORRUPT_ENGINE':'1'}, 'engine hash')):
            with self.subTest(injection=injection):
                self.fake_build()
                result=self.run_release('--prepare-build','3.0.0',**injection)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn(expected,result.stderr)
                self.assertIn('build:skip-install=1',self.calls())
                self.assertFalse((self.repo/'build/release/poke-token-bar-battle.rb').exists())

    def test_build_version_ignores_nested_tool_version(self):
        self.fake_build()
        result = self.run_release('--prepare-build', '3.0.0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.repo/'build/release/PokeTokenBarBattle.zip').exists())

    def test_certificate_extraction_attaches_optional_prefix_to_option(self):
        self.fake_build()
        result = self.run_release('--prepare-build', '3.0.0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(self.calls(), r'(?m)^codesign -d --extract-certificates=.+/cert build/PokeTokenBar Battle.app$')
        self.assertNotIn('codesign -d --extract-certificates ', self.calls())
        self.assertTrue((self.repo/'build/release/PokeTokenBarBattle.zip').exists())

    def test_legacy_deployment_command_uses_version_field(self):
        self.fake_build()
        result = self.run_release('--prepare-build', '3.0.0', OTOOL_OUTPUT=(
            'Load command 0\n      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n'
            '  version 15.0\n      sdk 15.0\nLoad command 1\n'
            '      cmd LC_LOAD_DYLIB\n current version 1234.5.6\n'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_malformed_or_duplicate_deployment_commands_reject_packaging(self):
        build = 'cmd LC_BUILD_VERSION\n minos 15.0\n ntools 1\n tool 3\n version 27106.1\n'
        legacy = 'cmd LC_VERSION_MIN_MACOSX\n version 15.0\n sdk 15.0\n'
        invalid = {
            'missing deployment command': 'cmd LC_LOAD_DYLIB\n version 15.0\n',
            'missing build minos': 'cmd LC_BUILD_VERSION\n version 15.0\n',
            'missing legacy version': 'cmd LC_VERSION_MIN_MACOSX\n minos 15.0\n',
            'malformed build minos': 'cmd LC_BUILD_VERSION\n minos 15.0 garbage\n',
            'malformed legacy version': 'cmd LC_VERSION_MIN_MACOSX\n version 15.0 garbage\n',
            'wrong build minimum': build.replace('minos 15.0', 'minos 14.0'),
            'wrong legacy minimum': legacy.replace('version 15.0', 'version 14.0'),
            'duplicate build minimum': build + ' minos 15.0\n',
            'duplicate legacy minimum': legacy + ' version 15.0\n',
            'mixed deployment commands': build + legacy,
            'duplicate legacy commands': legacy + legacy,
            'extra malformed command': legacy + 'cmd LC_BUILD_VERSION\n version 27106.1\n',
        }
        for label, output in invalid.items():
            with self.subTest(label=label):
                self.fake_build()
                result = self.run_release('--prepare-build', '3.0.0', OTOOL_OUTPUT=output)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('deployment target', result.stderr)
                self.assertFalse((self.repo/'build/release/PokeTokenBarBattle.zip').exists())

    def test_failed_rebuild_removes_previous_preview(self):
        self.fake_build()
        self.assertEqual(self.run_release('--prepare-build','3.0.0').returncode,0)
        self.assertTrue((self.repo/'build/release/poke-token-bar-battle.rb').exists())
        self.assertNotEqual(self.run_release('--prepare-build','3.0.0',BAD_JIT='1').returncode,0)
        self.assertFalse((self.repo/'build/release/poke-token-bar-battle.rb').exists())
        self.assertFalse((self.repo/'build/release/PokeTokenBarBattle.zip').exists())

    def test_missing_notes_prevents_build_or_signing(self):
        self.env.pop('PTB_NOTES_FILE')
        result=self.run_release('--prepare-build','3.0.0')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('PTB_NOTES_FILE',result.stderr)
        self.assertNotRegex(self.calls(),r'(?m)^(security|codesign|gh) ')

    def test_publication_requires_main_before_github_or_signing(self):
        result=self.run_release('3.0.0',PTB_FORK_RELEASE_READY='1')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('requires main',result.stderr)
        self.assertNotRegex(self.calls(),r'(?m)^(security|codesign|gh) ')

    def test_publication_rejects_missing_tap_before_build(self):
        result=self.run_release('3.0.0',PTB_FORK_RELEASE_READY='1',BRANCH='main')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Fork tap cask is missing',result.stderr)
        self.assertNotIn('build:',self.calls())
        self.assertNotRegex(self.calls(),r'(?m)^gh .* -X |^git (add|commit|push|tag) ')

    def test_cask_rejects_upstream_url_sha_minimum_or_app(self):
        helper=self.repo/'scripts/release-validate.py'
        result=subprocess.run(['python3',str(helper),'cask','2.5.6','a'*64],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for old,new in (('dding94/poketokenbar-battle','chattymin/PokeTokenBar'),
                        ('a'*64,'no_check'), ('>= :sequoia','>= :sonoma'),
                        ('app "PokeTokenBar Battle.app"','app "PokeTokenBar.app"')):
            with self.subTest(old=old):
                cask=self.repo/'invalid.rb';cask.write_text(result.stdout.replace(old,new))
                check=subprocess.run(['python3',str(helper),'check-cask',str(cask)],capture_output=True,text=True)
                self.assertNotEqual(check.returncode,0)

    def test_stubbed_publication_updates_version_and_sha_from_same_zip(self):
        self.fake_build()
        cask=self.repo/'existing.rb'
        result=subprocess.run(['python3',str(self.repo/'scripts/release-validate.py'),'cask','2.5.6','a'*64],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        cask.write_text(result.stdout)
        # All git/GitHub/build/signing tools here are fixture stubs. No external writes.
        result=self.run_release('3.0.0',PTB_FORK_RELEASE_READY='1',BRANCH='main',FAKE_TAP=str(cask),ALLOW_PUBLICATION_STUB='1')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('VERSION="3.0.0"',(self.repo/'scripts/build-app.sh').read_text())
        self.assertIn('gh release create v3.0.0 build/release/PokeTokenBarBattle.zip',self.calls())
        self.assertIn('gh api -X PUT repos/dding94/homebrew-tap/contents/Casks/poke-token-bar-battle.rb',self.calls())
        self.assertIn(hashlib.sha256(b'fixture zip bytes').hexdigest(),(self.repo/'build/release/poke-token-bar-battle.rb').read_text())
        import base64, json
        update=json.loads((self.repo/'calls.update.json').read_text())
        self.assertEqual(update['sha'],'existing-file-sha')
        published=base64.b64decode(update['content']).decode()
        self.assertIn('version "3.0.0"',published)
        self.assertIn(hashlib.sha256(b'fixture zip bytes').hexdigest(),published)
        self.assertNotIn('pkill ',self.calls())

    def test_prepare_build_never_runs_local_test_gate_or_ocr(self):
        self.fake_build()
        result=self.run_release('--prepare-build','3.0.0',PTB_CI_RUN_ID='12345')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('local-test-gate',self.calls())
        self.assertIn('gh api',self.calls())

    def test_prepare_build_requires_verified_ci_before_build_or_signing(self):
        self.fake_build()
        self.env.pop('PTB_CI_RUN_ID')
        result=self.run_release('--prepare-build','3.0.0')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PTB_CI_RUN_ID',result.stderr)
        self.assertNotIn('build:',self.calls())
        self.assertNotIn('local-test-gate',self.calls())
        self.assertNotIn('security ',self.calls())

    def test_ci_gate_rejects_stale_sha_missing_jobs_skips_and_missing_native_passes(self):
        self.fake_build()
        for mutation in ('sha','workflow','repository','failed-run','partial-jobs','skipped-job','skipped-step','native-skip','native-missing','attempt','job-run','job-sha','pagination'):
            with self.subTest(mutation=mutation):
                (self.repo/'calls').unlink(missing_ok=True)
                run=json.loads(json.dumps(self.ci_run));jobs=json.loads(json.dumps(self.ci_jobs));log=self.ci_log
                if mutation=='sha': run['head_sha']='2'*40
                elif mutation=='workflow': run['path']='.github/workflows/other.yml'
                elif mutation=='repository': run['repository']['full_name']='other/project'
                elif mutation=='failed-run': run['conclusion']='failure'
                elif mutation=='partial-jobs': jobs['jobs']=jobs['jobs'][:-1];jobs['total_count']-=1
                elif mutation=='skipped-job': jobs['jobs'][2]['conclusion']='skipped'
                elif mutation=='skipped-step': jobs['jobs'][2]['steps'][-1]['conclusion']='skipped'
                elif mutation=='native-skip': log=log.replace('passed=3 skipped=0','passed=2 skipped=1')
                elif mutation=='native-missing': log=log.replace('testSessionsRecoverCommittedResponseLossAndApplyDurablyOnce','otherTest')
                elif mutation=='attempt': jobs['jobs'][2]['run_attempt']=2
                elif mutation=='job-run': jobs['jobs'][2]['run_id']=54321
                elif mutation=='job-sha': jobs['jobs'][2]['head_sha']='2'*40
                elif mutation=='pagination': jobs['total_count']+=1
                for name,value in (('run',run),('jobs',jobs),('log',log)):
                    (self.repo/('ci-'+name+'.json')).write_text(value if isinstance(value,str) else json.dumps(value))
                result=self.run_release('--prepare-build','3.0.0')
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Release CI:',result.stderr)
                self.assertNotIn('build:',self.calls())
                self.assertNotIn('security ',self.calls())
                self.assertNotIn('local-test-gate',self.calls())

    def test_ci_gate_rejects_dirty_source_or_api_unavailability(self):
        self.fake_build()
        for injection in ({'DIRTY':'1'},{'API_UNAVAILABLE':'1'}):
            with self.subTest(injection=injection):
                result=self.run_release('--prepare-build','3.0.0',**injection)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Release CI:',result.stderr)
                self.assertNotIn('build:',self.calls())
                self.assertNotIn('local-test-gate',self.calls())

    def test_ci_rejects_untracked_source_but_allows_unrelated_logs(self):
        self.fake_build()
        rejected=self.run_release('--prepare-build','3.0.0',UNTRACKED_SOURCE='Sources/New.swift')
        self.assertNotEqual(rejected.returncode,0)
        self.assertIn('Untracked build/test inputs',rejected.stderr)
        self.assertNotIn('build:',self.calls())
        allowed=self.run_release('--prepare-build','3.0.0',UNTRACKED_SOURCE='scripts/build.log\nscripts/tests/__pycache__/test_release_workflow.cpython-314.pyc')
        self.assertEqual(allowed.returncode,0,allowed.stdout+allowed.stderr)
        self.assertNotIn('local-test-gate',self.calls())

    def test_publish_readiness_guard_stops_before_any_command(self):
        result=self.run_release('3.0.0')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls(),'')

if __name__=='__main__': unittest.main()
