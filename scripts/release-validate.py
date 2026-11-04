#!/usr/bin/env python3
"""Local fork release validation. Reads only source, artifacts, and public signing metadata."""
import hashlib
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = 'dding94/poketokenbar-battle'
APP = 'PokeTokenBar Battle'
EXEC = 'PokeTokenBarBattle'
BUNDLE = 'io.github.dding94.poketokenbar-battle'
LABEL = BUNDLE + '.login'
CASK = 'poke-token-bar-battle'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value), 'Version must be X.Y.Z (no leading zeros)')
    return value


def run(*args):
    result = subprocess.run(args, check=True, capture_output=True)
    return result.stdout + result.stderr


def source_check(root):
    root = Path(root)
    identity = (root/'Sources/PokeTokenBar/Core/AppIdentity.swift').read_text().split('enum Upstream {')[0]
    values = {'bundleID': BUNDLE, 'appName': APP, 'executableName': EXEC, 'stateDirectoryName': EXEC,
              'loginAgentLabel': LABEL, 'releaseRepo': REPO, 'caskName': CASK}
    for name, value in values.items():
        require(f'static let {name} = "{value}"' in identity, f'Fork AppIdentity mismatch: {name}')
    build = (root/'scripts/build-app.sh').read_text()
    for name, value in {'APP_NAME': APP, 'EXEC_NAME': EXEC, 'BUNDLE_ID': BUNDLE, 'LOGIN_LABEL': LABEL}.items():
        require(re.search(rf'^{name}="{re.escape(value)}"$', build, re.M), f'Fork build identity mismatch: {name}')
    require('"/Applications/$APP_NAME.app"' in build, 'Fork installation path guard missing')
    updater = (root/'Sources/PokeTokenBar/Core/UpdateChecker.swift').read_text()
    require('liveLatestRelease(repo: AppIdentity.releaseRepo)' in updater and 'AppIdentity.caskName' in updater,
            'Updater must use fork identity')
    entitlements = plistlib.loads((root/'scripts/battle.entitlements').read_bytes())
    require(entitlements.get('com.apple.security.cs.allow-jit') is True, 'Source JIT entitlement missing')


def engine_pins(root):
    manifest = (root/'Sources/PokeTokenBar/Core/BattleEngineManifest.swift').read_text()
    archive = (root/'Sources/PokeTokenBar/Core/BattleEngineArchive.swift').read_text()
    current = re.search(r'static let sha256 = "([0-9a-f]{64})"', manifest)
    pins = re.findall(r'Entry\(hash: "([0-9a-f]{64})"', archive)
    require(current and pins and len(pins) == len(set(pins)), 'Missing/duplicate engine trust pins')
    require(current[1] in pins, 'Current engine is not archived')
    return current[1], pins


def bundle_check(root, app, target_version, leaf):
    root, app = Path(root), Path(app)
    version(target_version)
    require(re.fullmatch(r'[A-Fa-f0-9]{40}', leaf), 'PTB_EXPECTED_LEAF must be a 40-digit certificate SHA-1')
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    for name, value in {'CFBundleIdentifier': BUNDLE, 'CFBundleName': APP, 'CFBundleExecutable': EXEC,
                        'CFBundleShortVersionString': target_version, 'LSMinimumSystemVersion': '15.0'}.items():
        require(info.get(name) == value, f'Bundle metadata mismatch: {name}')
    agent = plistlib.loads((app/f'Contents/Library/LaunchAgents/{LABEL}.plist').read_bytes())
    require(agent.get('Label') == LABEL and agent.get('ProgramArguments') == [f'/Applications/{APP}.app/Contents/MacOS/{EXEC}'],
            'Fork LaunchAgent/install path mismatch')
    binary = app/f'Contents/MacOS/{EXEC}'
    for arch in ('arm64', 'x86_64'):
        run('lipo', str(binary), '-verify_arch', arch)
        load = run('otool', '-arch', arch, '-l', str(binary)).decode()
        # Each deployment command has its own minimum field. BUILD_VERSION also
        # contains nested tool "version" fields, which are not deployment targets.
        blocks = re.split(r'^\s*cmd\s+', load, flags=re.M)
        deployment = [(command, body) for block in blocks
                      for command, _, body in [block.partition('\n')]
                      if command.strip() in ('LC_BUILD_VERSION', 'LC_VERSION_MIN_MACOSX')]
        require(len(deployment) == 1, f'{arch} deployment target must have exactly one macOS load command')
        command, body = deployment[0]
        field = 'minos' if command.strip() == 'LC_BUILD_VERSION' else 'version'
        minima = [value.strip() for value in re.findall(rf'^\s*{field}\b([^\n]*)$', body, re.M)]
        require(len(minima) == 1 and minima[0] in ('15.0','15.0.0'), f'{arch} deployment target must be macOS 15.0')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    entitlement_output = run('codesign', '-d', '--entitlements', ':-', str(app))
    xml = re.search(rb'<\?xml.*?</plist>', entitlement_output, re.S)
    require(xml is not None and plistlib.loads(xml[0]).get('com.apple.security.cs.allow-jit') is True,
            'Signed bundle JIT entitlement missing')
    # codesign extraction exports public certificate DER only; no private key is read.
    with tempfile.TemporaryDirectory(prefix='ptb-public-certificate-') as directory:
        prefix = str(Path(directory)/'cert')
        run('codesign', '-d', '--extract-certificates=' + prefix, str(app))
        certificate = Path(prefix+'0')
        require(certificate.is_file(), 'Ad-hoc/unsigned release bundle has no certificate leaf')
        require(hashlib.sha1(certificate.read_bytes()).hexdigest().upper() == leaf.upper(), 'Built certificate leaf mismatch')
    current, pins = engine_pins(root)
    resources = app/'Contents/Resources'
    for pin in pins:
        path = resources/'battle-engine.js' if pin == current else resources/f'battle-engines/{pin}.js'
        require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == pin, f'Packaged engine hash mismatch: {pin}')


def cask_text(target_version, sha):
    version(target_version)
    require(re.fullmatch(r'[0-9a-f]{64}', sha), 'Cask SHA256 must be 64 lowercase hex digits')
    return f'''cask "{CASK}" do
  version "{target_version}"
  sha256 "{sha}"

  url "https://github.com/{REPO}/releases/download/v#{{version}}/{EXEC}.zip"
  name "{APP}"
  desc "Menu bar companion with local practice and online battles"
  homepage "https://github.com/{REPO}"

  depends_on macos: ">= :sequoia"
  app "{APP}.app"
end
'''


def check_cask(path):
    text = Path(path).read_text()
    ver = re.search(r'^  version "([^"]+)"$', text, re.M)
    sha = re.search(r'^  sha256 "([^"]+)"$', text, re.M)
    require(ver and sha, 'Missing cask version/SHA256')
    require(text == cask_text(ver[1], sha[1]), 'Cask must match fork URL/SHA/macOS15/app template exactly')


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'source' and len(args) == 1: source_check(*args)
        elif mode == 'bundle' and len(args) == 4: bundle_check(*args)
        elif mode == 'cask' and len(args) == 2: print(cask_text(*args), end='')
        elif mode == 'check-cask' and len(args) == 1: check_cask(*args)
        elif mode == 'version' and len(args) == 1: version(*args)
        else: raise ValueError('Use source ROOT | bundle ROOT APP VERSION LEAF | cask VERSION SHA | check-cask FILE | version VERSION')
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        sys.exit(f'Release validation: {error}')
