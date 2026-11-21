#!/usr/bin/env python3
"""Prepare and publish a signed Mediaforge release for Dropbox and Sparkle."""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build/distribution'
RESOURCES = ROOT / 'Resources'
PROJECT = ROOT / 'Mediaforge.xcodeproj'
APP_NAME = 'Mediaforge'
APP_BUNDLE = APP_NAME + '.app'
IDENTITY = 'Developer ID Application: Soundbrenner Limited (7L872R293R)'
TEAM = '7L872R293R'
BUNDLE_ID = 'com.soundbrenner.mediagenerator'
KEY_ACCOUNT = 'soundbrenner-pixel'
BUCKET = 'soundbrenner-pixel-releases'
SP = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
UPDATE_INFO = plistlib.loads((RESOURCES / 'DirectUpdateInfo.plist').read_bytes())
FEED_URL = UPDATE_INFO['SUFeedURL']
DOWNLOADS = FEED_URL.removesuffix('appcast.xml')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args, **kwargs):
    return run(*args, stdout=subprocess.PIPE, text=True, **kwargs).stdout.strip()


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def sign(path, *options):
    run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', IDENTITY, *options, path)


def stapled(path):
    return path.exists() and subprocess.run(
        ['xcrun', 'stapler', 'validate', path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0


def notarize(path, app, workspace):
    if stapled(path):
        return
    if profile := os.environ.get('MEDIAFORGE_NOTARY_PROFILE'):
        submission = path
        if path == app:
            submission = workspace / 'notary-app.zip'
            submission.unlink(missing_ok=True)
            run('ditto', '-c', '-k', '--keepParent', '--sequesterRsrc', app, submission)
        result = json.loads(output('xcrun', 'notarytool', 'submit', submission, '--wait',
                                   '--timeout', '20m', '--keychain-profile', profile, '--output-format', 'json'))
        if result.get('status') != 'Accepted':
            raise RuntimeError(f"Apple notarization status: {result.get('status')} ({result.get('id')})")
    else:
        # Use Xcode's signed-in account, as Showtime does. The DMG travels inside a
        # temporary carrier app so Apple issues a separate ticket for the disk image.
        archive = workspace / ('App.xcarchive' if path == app else 'DMG.xcarchive')
        export = archive / 'Export'
        exported_app = export / APP_BUNDLE
        if not (archive / '.submitted').exists():
            if archive.exists():
                shutil.rmtree(archive)
            archived_app = archive / 'Products/Applications' / APP_BUNDLE
            archived_app.parent.mkdir(parents=True)
            run('ditto', app, archived_app)
            if path != app:
                carrier = archived_app / 'Contents/Resources' / path.name
                shutil.copy2(path, carrier)
                sign(archived_app, '--preserve-metadata=entitlements')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            properties = {key: info[key] for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')}
            properties.update(ApplicationPath=f'Applications/{APP_BUNDLE}', SigningIdentity=IDENTITY, Team=TEAM)
            (archive / 'Info.plist').write_bytes(plistlib.dumps({
                'ArchiveVersion': 2, 'CreationDate': datetime.now(timezone.utc).replace(tzinfo=None),
                'Name': APP_NAME, 'SchemeName': APP_NAME, 'ApplicationProperties': properties,
            }))
            run('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', export,
                '-exportOptionsPlist', RESOURCES / 'ExportOptions-DeveloperID.plist', '-allowProvisioningUpdates')
            (archive / '.submitted').touch()

        log = archive / 'notarization-export.log'
        if not stapled(exported_app):
            for _ in range(30):
                with log.open('w') as stream:
                    result = subprocess.run(['xcodebuild', '-exportNotarizedApp', '-archivePath', archive,
                                             '-exportPath', export], stdout=stream, stderr=subprocess.STDOUT)
                if result.returncode == 0:
                    break
                status = log.read_text()
                retryable = ('processing and not ready', 'Code=-1009', 'Code=-1001', 'Code=-1005')
                if not any(message in status for message in retryable):
                    raise RuntimeError(f'Xcode notarization export failed. See {log}')
                time.sleep(5)
            else:
                raise RuntimeError('Apple is still processing the submission. Rerun prepare with --resume.')

        if path == app:
            # Xcode may re-sign the app during export. Use the notarized copy
            # only after checking that it kept the sandbox and XPC permissions.
            original = plistlib.loads(run('codesign', '-d', '--xml', '--entitlements', '-', app,
                                          stdout=subprocess.PIPE).stdout)
            exported = plistlib.loads(run('codesign', '-d', '--xml', '--entitlements', '-', exported_app,
                                          stdout=subprocess.PIPE).stdout)
            if any(exported.get(key) != value for key, value in original.items()):
                raise RuntimeError('Xcode export changed Mediaforge’s required sandbox entitlements.')
            if exported.get('com.apple.security.get-task-allow'):
                raise RuntimeError('Xcode export enabled the debugger entitlement.')
            run('xcrun', 'stapler', 'validate', exported_app)
            with tempfile.TemporaryDirectory(dir=workspace) as staging:
                backup = Path(staging) / APP_BUNDLE
                app.rename(backup)
                try:
                    exported_app.rename(app)
                except OSError:
                    backup.rename(app)
                    raise

    if not stapled(path):
        run('xcrun', 'stapler', 'staple', path)
    run('xcrun', 'stapler', 'validate', path)


def build_app(app, sparkle, version, build):
    if output(sparkle / 'bin/generate_keys', '--account', KEY_ACCOUNT, '-p') != UPDATE_INFO['SUPublicEDKey']:
        raise RuntimeError('The Mediaforge Sparkle signing key in Keychain must match DirectUpdateInfo.plist.')
    derived = WORK / 'DerivedData'
    run('xcodebuild', '-project', PROJECT, '-scheme', APP_NAME, '-configuration', 'Release',
        '-destination', 'generic/platform=macOS', '-derivedDataPath', derived,
        'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=MEDIAFORGE_DIRECT_DISTRIBUTION',
        f'FRAMEWORK_SEARCH_PATHS={sparkle}', 'OTHER_LDFLAGS=-framework Sparkle', '-quiet', 'build')
    app.parent.mkdir(parents=True, exist_ok=True)
    run('ditto', derived / 'Build/Products/Release' / APP_BUNDLE, app)
    info_file = app / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    if (info['CFBundleShortVersionString'], info['CFBundleVersion'], info['CFBundleIdentifier']) != (version, build, BUNDLE_ID):
        raise RuntimeError('Unexpected version or bundle identifier in built app.')
    info.update(UPDATE_INFO)
    info_file.write_bytes(plistlib.dumps(info))

    framework = app / 'Contents/Frameworks/Sparkle.framework'
    framework.parent.mkdir(exist_ok=True)
    run('ditto', sparkle / 'Sparkle.framework', framework)
    run('xattr', '-cr', app)
    bundle = framework / 'Versions/Current'
    for helper in ('Autoupdate', 'Updater.app', 'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc'):
        sign(bundle / helper, '--preserve-metadata=entitlements')
    sign(framework)
    entitlements = plistlib.loads((ROOT / 'Mediaforge.entitlements').read_bytes())
    entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = [
        f'{BUNDLE_ID}-spks', f'{BUNDLE_ID}-spki',
    ]
    entitlements_path = app.parent / 'Direct.entitlements'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    sign(app, '--entitlements', entitlements_path)
    run('codesign', '--verify', '--deep', '--strict', app)
    architectures = output('lipo', '-archs', app / 'Contents/MacOS' / APP_NAME).split()
    if set(architectures) != {'arm64', 'x86_64'}:
        raise RuntimeError(f'Expected a universal app. Found: {architectures}')


def verify_package(sparkle, release, version, build):
    dmg, archive, feed = release_paths(release, version, build)
    tool = sparkle / 'bin/sign_update'
    run(tool, '--account', KEY_ACCOUNT, '--verify', feed)
    item = ET.parse(feed).find('./channel/item')
    enclosure = item.find('enclosure')
    if (item.findtext(SP + 'version') != build or item.findtext(SP + 'shortVersionString') != version
            or enclosure.get('url') != DOWNLOADS + archive.name or int(enclosure.get('length')) != archive.stat().st_size):
        raise RuntimeError('The appcast version, build, or enclosure does not match this release.')
    run(tool, '--account', KEY_ACCOUNT, '--verify', archive, enclosure.get(SP + 'edSignature'))
    run('xcrun', 'stapler', 'validate', dmg)
    run('codesign', '--verify', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)


def release_paths(release, version, build):
    stem = f'Mediaforge-{version}-{build}'
    return release / (stem + '.dmg'), release / (stem + '.zip'), release / 'appcast.xml'


def prepare(sparkle, version, build, workspace, resume):
    release = workspace / 'release'
    dmg, archive, feed = release_paths(release, version, build)
    app = workspace / APP_BUNDLE
    notes = RESOURCES / 'UpdateHighlights.json'
    embed = ROOT / 'scripts/embed-update-highlights.py'
    run('python3', embed, notes, build)
    if resume:
        if not app.exists():
            raise RuntimeError('There is no signed app to resume. Run prepare first.')
    else:
        if workspace.exists():
            raise RuntimeError('This build already has release state. Use --resume or increment the build number.')
        with tempfile.TemporaryDirectory(dir=WORK) as staging:
            staged_workspace = Path(staging) / 'build'
            build_app(staged_workspace / APP_BUNDLE, sparkle, version, build)
            staged_workspace.rename(workspace)
    notarize(app, app, workspace)
    run('codesign', '--verify', '--deep', '--strict', app)
    run('spctl', '--assess', '--type', 'execute', app)
    release.mkdir(exist_ok=True)
    if not dmg.exists():
        with tempfile.TemporaryDirectory(dir=workspace) as staging:
            volume = Path(staging) / 'volume'
            volume.mkdir()
            run('ditto', app, volume / APP_BUNDLE)
            (volume / 'Applications').symlink_to('/Applications')
            candidate = Path(staging) / dmg.name
            run('hdiutil', 'create', '-quiet', '-srcfolder', volume, '-volname', APP_NAME, '-format', 'UDZO', candidate)
            sign(candidate)
            candidate.rename(dmg)
    notarize(dmg, app, workspace)

    if not feed.exists():
        archive.unlink(missing_ok=True)
        run('ditto', '-c', '-k', '--keepParent', '--sequesterRsrc', app, archive)
        with tempfile.TemporaryDirectory(dir=workspace) as staging:
            feed_directory = Path(staging)
            os.link(archive, feed_directory / archive.name)
            run(sparkle / 'bin/generate_appcast', '--account', KEY_ACCOUNT, '--maximum-deltas', '0',
                '--download-url-prefix', DOWNLOADS, feed_directory)
            staged_feed = feed_directory / feed.name
            run('python3', embed, notes, build, staged_feed)
            run(sparkle / 'bin/sign_update', '--account', KEY_ACCOUNT, staged_feed)
            staged_feed.rename(feed)
    verify_package(sparkle, release, version, build)
    print(f'Prepared and verified {release}', flush=True)


def fetch(name, directory):
    destination = directory / name
    request = Request(DOWNLOADS + name, headers={'User-Agent': 'Mediaforge release verification/1.0'})
    try:
        with urlopen(request, timeout=60) as response, destination.open('wb') as stream:
            shutil.copyfileobj(response, stream)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise
    return destination


def publish(sparkle, version, build, release, team_dir):
    dmg, archive, feed = release_paths(release, version, build)
    verify_package(sparkle, release, version, build)
    if not team_dir.is_dir():
        raise RuntimeError(f'Dropbox Team folder is unavailable: {team_dir}')
    wrangler = ['npx', '--yes', 'wrangler@4.151.3']
    if command := os.environ.get('MEDIAFORGE_WRANGLER'):
        wrangler = [command]
    env = dict(os.environ, CLOUDFLARE_ACCOUNT_ID='7c28cd9ef2aed1dcdea11e46b57cff99')
    if env.get('CLOUDFLARE_API_KEY'):
        env.pop('CLOUDFLARE_API_TOKEN', None)
    elif not env.get('CLOUDFLARE_API_TOKEN'):
        for name, service in [('CLOUDFLARE_API_TOKEN', 'codex-cloudflare-api-token'),
                              ('CLOUDFLARE_API_KEY', 'codex-cloudflare-global-api-key')]:
            result = subprocess.run(['security', 'find-generic-password', '-a', env['USER'], '-s', service, '-w'],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                env[name] = result.stdout.strip()
                break
    if env.get('CLOUDFLARE_API_KEY'):
        env.setdefault('CLOUDFLARE_EMAIL', 'florian@soundbrenner.com')
    if not (env.get('CLOUDFLARE_API_KEY') or env.get('CLOUDFLARE_API_TOKEN')):
        raise RuntimeError('No Cloudflare release credential is available.')
    with tempfile.TemporaryDirectory(dir=WORK) as temporary:
        directory = Path(temporary)
        old_feed = fetch(feed.name, directory)
        if old_feed:
            run(sparkle / 'bin/sign_update', '--account', KEY_ACCOUNT, '--verify', old_feed)
            old_build = int(ET.parse(old_feed).findtext(f'./channel/item/{SP}version'))
            if old_build > int(build) or (old_build == int(build) and digest(old_feed) != digest(feed)):
                raise RuntimeError('The live feed already contains this build with different contents, or a newer build.')

        for artifact, content_type in [(archive, 'application/zip'), (dmg, 'application/x-apple-diskimage'),
                                       (feed, 'application/rss+xml')]:
            remote = fetch(artifact.name, directory)
            if remote and digest(remote) == digest(artifact):
                continue
            if remote and artifact != feed:
                raise RuntimeError(f'Published artifacts are immutable: {artifact.name}. Increment the build number.')
            run(*wrangler, 'r2', 'object', 'put', f'{BUCKET}/{artifact.name}', '--file', artifact,
                '--content-type', content_type, '--remote', env=env, cwd=ROOT / 'release-host')
            remote = fetch(artifact.name, directory)
            if not remote or digest(remote) != digest(artifact):
                raise RuntimeError(f'Cloudflare download verification failed for {artifact.name}.')

    with tempfile.NamedTemporaryFile(prefix='.mediaforge-installer-', suffix='.tmp', dir=team_dir, delete=False) as stream:
        temporary_installer = Path(stream.name)
    destination = team_dir / 'Mediaforge.dmg'
    try:
        shutil.copyfile(dmg, temporary_installer)
        if digest(temporary_installer) != digest(dmg):
            raise RuntimeError('Dropbox copy failed checksum verification.')
        temporary_installer.chmod(0o644)
        temporary_installer.replace(destination)
        if digest(destination) != digest(dmg):
            raise RuntimeError('Dropbox installer failed read-back verification.')
    finally:
        temporary_installer.unlink(missing_ok=True)
    print(f'Published and verified {FEED_URL}\nDropbox installer: {destination}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'publish'])
    parser.add_argument('--resume', action='store_true', help='Reuse the signed app and resume notarization or packaging.')
    parser.add_argument('--team-dir', type=Path, default=Path.home() / 'Library/CloudStorage/Dropbox-Soundbrenner/Team')
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    with (WORK / 'release.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sparkle = Path(output('bash', ROOT / 'scripts/fetch-sparkle.sh'))
        project = (PROJECT / 'project.pbxproj').read_text()
        versions = set(re.findall(r'MARKETING_VERSION = (\d+\.\d+\.\d+);', project))
        builds = set(re.findall(r'CURRENT_PROJECT_VERSION = ([1-9]\d*);', project))
        if len(versions) != 1 or len(builds) != 1:
            raise RuntimeError('Set a consistent version and build number in the Xcode project.')
        version, build = versions.pop(), builds.pop()
        workspace = WORK / f'{version}-{build}'
        if args.action == 'prepare':
            prepare(sparkle, version, build, workspace, args.resume)
        else:
            publish(sparkle, version, build, workspace / 'release', args.team_dir.expanduser())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
