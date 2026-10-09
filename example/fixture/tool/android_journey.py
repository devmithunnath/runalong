#!/usr/bin/env python3
"""Small external ADB journey for the already-running public Android fixture.
No Runalong imports or special test wrappers. Pass an explicit device serial.
"""
import argparse
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
args = parser.parse_args()


def adb(*arguments):
    return subprocess.check_output(['adb', '-s', args.device, *arguments], text=True, timeout=15)


def find(label, deadline=12):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        adb('shell', 'uiautomator', 'dump', '/sdcard/runalong-fixture-ui.xml')
        tree = ET.fromstring(adb('shell', 'cat', '/sdcard/runalong-fixture-ui.xml'))
        for node in tree.iter('node'):
            if label in (node.get('text'), node.get('content-desc')):
                return node
        time.sleep(.25)
    raise AssertionError(f'Fixture control did not appear: {label}')


def tap(label):
    bounds = [int(n) for n in re.findall(r'\d+', find(label).get('bounds', ''))]
    if len(bounds) != 4:
        raise AssertionError(f'No usable bounds: {label}')
    adb('shell', 'input', 'tap', str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2))


tap('Open catalogue')
tap('Run animation')
find('Animation complete')
print('PASS: catalogue animation completed')
