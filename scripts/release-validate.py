#!/usr/bin/env python3
"""Local fork release validation. Reads only source, artifacts, and public signing metadata."""
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

REPO = 'dding94/poketokenbar-battle'
APP = 'PokeTokenBattle'
EXEC = 'PokeTokenBarBattle'
BUNDLE = 'io.github.dding94.poketokenbar-battle'
LABEL = BUNDLE + '.login'
CASK = 'poke-token-bar-battle'
# Display name and app folder of the already published 2.6.0 cask (before the PokeTokenBattle rename).
LEGACY_APP = 'PokeTokenBar Battle'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value), 'Version must be X.Y.Z (no leading zeros)')
    return value


def run(*args):
    result = subprocess.run(args, check=True, capture_output=True)
    return result.stdout + result.stderr


def server_url(value):
    """Plain https origin for the build-time server address; the value is never echoed (it may be the real one)."""
    message = 'Server URL must be a plain https origin (host and optional port; no path, query, fragment or credentials)'
    require(value and value == value.strip() and '?' not in value and '#' not in value, message)
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise ValueError(message) from None
    host = parts.hostname or ''
    require(parts.scheme == 'https' and '@' not in parts.netloc and parts.path in ('', '/')
            and re.fullmatch(r'[a-z0-9]([a-z0-9.-]*[a-z0-9])?', host) and (port is None or 1 <= port <= 65535), message)
    return f'https://{host}' + (f':{port}' if port not in (None, 443) else '')


# Account labels that are documentation placeholders; any other <worker>.<account>.workers.dev is treated as real.
PLACEHOLDER_ACCOUNTS = {b'example', b'secret-sub', b'subdomain'}
WORKERS_DEV = re.compile(rb'[A-Za-z0-9][A-Za-z0-9-]*\.([A-Za-z0-9][A-Za-z0-9-]*)\.workers\.dev', re.I)
SKIPPED_DIRECTORIES = {'.git', 'node_modules', '.build', 'build', '.wrangler', '.swiftpm', 'DerivedData'}


def address_check(root):
    """The real server address lives only in a local build input. Report file names, never the address."""
    root = Path(root)
    found = []
    for directory, names, files in os.walk(root):
        relative = Path(directory).relative_to(root)
        names[:] = [n for n in names if n not in SKIPPED_DIRECTORIES and not (relative.parts[-1:] == ('.claude',) and n == 'worktrees')]
        for name in files:
            path = Path(directory) / name
            try:
                if path.is_symlink() or path.stat().st_size > 20_000_000: continue
                data = path.read_bytes()
            except OSError:
                continue
            if any(m[1].lower() not in PLACEHOLDER_ACCOUNTS for m in WORKERS_DEV.finditer(data)):
                found.append(str(path.relative_to(root)))
    require(not found, 'Real workers.dev address must not be committed (keep it in the local PTB_BATTLE_SERVER_URL build input): '
            + ', '.join(sorted(found)))


def source_check(root):
    root = Path(root)
    address_check(root)
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
    # Only release builds reach this check, and a release must carry the address (build-app.sh embeds it).
    require('PTBBattleServerURL' in info, 'Release bundle has no embedded server address (PTB_BATTLE_SERVER_URL)')
    require(isinstance(info['PTBBattleServerURL'], str) and server_url(info['PTBBattleServerURL']) == info['PTBBattleServerURL'],
            'Embedded server URL is not a normalized https origin')
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


def cask_text(target_version, sha, app=APP):
    version(target_version)
    require(re.fullmatch(r'[0-9a-f]{64}', sha), 'Cask SHA256 must be 64 lowercase hex digits')
    return f'''cask "{CASK}" do
  version "{target_version}"
  sha256 "{sha}"

  url "https://github.com/{REPO}/releases/download/v#{{version}}/{EXEC}.zip"
  name "{app}"
  desc "Menu bar companion with local practice and online battles"
  homepage "https://github.com/{REPO}"

  depends_on macos: ">= :sequoia"
  app "{app}.app"
end
'''


def check_cask(path):
    text = Path(path).read_text()
    ver = re.search(r'^  version "([^"]+)"$', text, re.M)
    sha = re.search(r'^  sha256 "([^"]+)"$', text, re.M)
    require(ver and sha, 'Missing cask version/SHA256')
    require(text == cask_text(ver[1], sha[1]), 'Cask must match fork URL/SHA/macOS15/app template exactly')


def check_published_cask(path):
    """The cask already in the tap before publication: the current template, or the pre-rename 2.6.0 template.

    The publication step rewrites it with the current template, so the first release across the rename must be able
    to start from the old `app` folder. Everything else (URL, minimum macOS, checksum form) is still pinned."""
    text = Path(path).read_text()
    ver = re.search(r'^  version "([^"]+)"$', text, re.M)
    sha = re.search(r'^  sha256 "([^"]+)"$', text, re.M)
    require(ver and sha, 'Missing cask version/SHA256')
    require(text in (cask_text(ver[1], sha[1]), cask_text(ver[1], sha[1], LEGACY_APP)),
            'Published cask must match the fork template (current or pre-rename) exactly')


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'source' and len(args) == 1: source_check(*args)
        elif mode == 'bundle' and len(args) == 4: bundle_check(*args)
        elif mode == 'cask' and len(args) == 2: print(cask_text(*args), end='')
        elif mode == 'check-cask' and len(args) == 1: check_cask(*args)
        elif mode == 'check-published-cask' and len(args) == 1: check_published_cask(*args)
        elif mode == 'version' and len(args) == 1: version(*args)
        elif mode == 'server-url' and len(args) == 1: print(server_url(*args))
        elif mode == 'addresses' and len(args) == 1: address_check(*args)
        else: raise ValueError('Use source ROOT | bundle ROOT APP VERSION LEAF | cask VERSION SHA | check-cask FILE | version VERSION')
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        sys.exit(f'Release validation: {error}')
