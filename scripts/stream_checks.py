"""Shared assertions for local demo stream verification (no application dependency)."""
import re


def check_timing(pts, decoded_fps, fps=60):
    gaps = [b - a for a, b in zip(pts, pts[1:]) if a >= pts[0] + 1]
    assert gaps, 'FAIL: no steady-state video timestamps'
    maximum = max(gaps)
    print(f'maximum video PTS gap after first second: {maximum * 1000:.3f} ms')
    assert maximum < 1.9 / fps, 'FAIL: video stutter'
    assert abs(decoded_fps - fps) <= 0.5, 'FAIL: decoded fps'


def check_drops(log):
    drops = re.findall(r'dropped render=(\d+) encoder=(\d+)', log)
    admissions = re.findall(r'queueRejected=(\d+) inFlightRejected=(\d+)', log)
    assert drops and admissions, 'FAIL: missing drop statistics'
    assert all(int(r) == 0 and int(e) == 0 for r, e in drops + admissions), 'FAIL: render/encoder drops'
    uploads = re.findall(r'stream upload .* dropped=(\d+)', log)
    assert all(int(n) == 0 for n in uploads), 'FAIL: publisher drops'
    print('render drops=0 encoder drops=0 queueRejected=0 inFlightRejected=0')


def expected_actions(script):
    result = []
    for step in script.split(','):
        m = re.fullmatch(r'(\d+(?:\.\d+)?):(next|prev|punch|marker|canvas=(?:wide|vertical)|scene=.+)', step)
        assert m, f'FAIL: invalid scripted action: {step}'
        result.append((float(m[1]), m[2]))
    assert result, 'FAIL: no expected actions'
    return [a for _, a in sorted(result)]


def check_actions(script, actual):
    assert actual == expected_actions(script), f'FAIL: expected {expected_actions(script)}, received {actual}'
