#!/usr/bin/env python3
"""Embed native Sparkle release highlights before signing the appcast."""

import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
NOTES_NAMESPACE = 'https://soundbrenner.com/ns/updates'
NOTES = f'{{{NOTES_NAMESPACE}}}releaseHighlights'


def read_highlights(path):
    releases = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(releases, dict) or not releases:
        raise ValueError('Release highlights must be keyed by build number.')
    for build, bullets in releases.items():
        if not re.fullmatch(r'[1-9][0-9]*', build):
            raise ValueError(f'Invalid build number: {build}')
        if not isinstance(bullets, list) or not 1 <= len(bullets) <= 3:
            raise ValueError(f'Build {build} needs one to three highlights.')
        if any(not isinstance(b, str) or not b.strip() or len(b.splitlines()) != 1 for b in bullets):
            raise ValueError(f'Build {build} has an empty or multiline highlight.')
    return releases


def embed_highlights(feed, releases, current_build):
    ET.register_namespace('sparkle', SPARKLE[1:-1])
    ET.register_namespace('dc', 'http://purl.org/dc/elements/1.1/')
    ET.register_namespace('soundbrenner', NOTES_NAMESPACE)
    tree = ET.parse(feed)
    found_current = False
    for item in tree.findall('./channel/item'):
        enclosure = item.find('enclosure')
        build = item.findtext(SPARKLE + 'version')
        if build is None and enclosure is not None:
            build = enclosure.get(SPARKLE + 'version')
        if build not in releases:
            continue
        if build == current_build:
            found_current = True
        for element in list(item):
            if element.tag in ('description', NOTES, SPARKLE + 'releaseNotesLink'):
                item.remove(element)
        # Already-installed clients can display this with Sparkle alone.
        description = ET.SubElement(item, 'description', {SPARKLE + 'format': 'plain-text'})
        description.text = '\n'.join(f'• {bullet}' for bullet in releases[build])
        history = {key: bullets for key, bullets in releases.items() if int(key) <= int(build)}
        ET.SubElement(item, NOTES).text = json.dumps(history, ensure_ascii=False, separators=(',', ':'))
    if not found_current:
        raise ValueError(f'Build {current_build} is missing from the appcast.')
    tree.write(feed, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('highlights', type=Path)
    parser.add_argument('build')
    parser.add_argument('appcast', type=Path, nargs='?')
    args = parser.parse_args()
    try:
        releases = read_highlights(args.highlights)
        if args.build not in releases:
            raise ValueError(f'Add release highlights for build {args.build} to {args.highlights}.')
        if args.appcast is not None:
            embed_highlights(args.appcast, releases, args.build)
    except (OSError, ValueError, ET.ParseError) as error:
        parser.exit(1, f'{error}\n')
