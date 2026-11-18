#!/usr/bin/env python3
"""Write the fork's appcast from an immutable, already-signed release archive."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser()
p.add_argument('--version', required=True)
p.add_argument('--build', required=True)
p.add_argument('--archive', type=Path, required=True)
p.add_argument('--signature', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', sparkle)
rss = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Boring Notch — Offbrand-Window fork'
ET.SubElement(channel, 'link').text = 'https://github.com/Offbrand-Window/boring.notch/releases'
ET.SubElement(channel, 'description').text = 'Signed updates for the Offbrand-Window fork of Boring Notch.'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'{a.version} — Vibing Deer'
ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
ET.SubElement(item, f'{{{sparkle}}}version').text = a.build
ET.SubElement(item, f'{{{sparkle}}}shortVersionString').text = a.version
ET.SubElement(item, f'{{{sparkle}}}minimumSystemVersion').text = '14.0'
ET.SubElement(item, f'{{{sparkle}}}hardwareRequirements').text = 'arm64'
ET.SubElement(item, 'description').text = 'Vibing Deer: Bluetooth and AirPods activities, Low Profile HUD, and lock-screen transitions. See the fork release notes for known limitations.'
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/Offbrand-Window/boring.notch/releases/download/v{a.version}/{a.archive.name}',
    'length': str(a.archive.stat().st_size),
    'type': 'application/octet-stream',
    f'{{{sparkle}}}edSignature': a.signature,
})
ET.indent(rss)
a.output.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(rss).write(a.output, encoding='utf-8', xml_declaration=True)
