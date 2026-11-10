"""Regression fixtures for the embedded received-file checker (no ffmpeg/device needed)."""
import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

CHECK = (pathlib.Path(__file__).with_name('stream-selftest.sh').read_text()
         .split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0])

class ReceivedStreamChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = pathlib.Path(self.tmp.name)
        self.write('probe.json', json.dumps({'streams': [
            dict(codec_type='video', codec_name='h264', width=1920, height=1080, r_frame_rate='60/1', nb_read_frames='1200'),
            dict(codec_type='audio', codec_name='aac', sample_rate='48000', channels=2)], 'format': {'duration': '20'}}))
        self.pts = [i/60 for i in range(1200)]
        self.write('app.log', 'dropped render=0 encoder=0')
        self.write('flash.log', '\n'.join(f'pts_time:{i/60}\nlavfi.signalstats.YAVG={235 if i%60==0 else 20}' for i in range(1200)))
        for name in ['beep.log', 'mic.log']:
            self.write(name, '\n'.join(f'silence_end: {i+.002}' for i in range(20)))

    def write(self, name, value):
        (self.p/name).write_text(value)

    def check(self):
        self.write('pts.json', json.dumps({'frames': [dict(best_effort_timestamp_time=t) for t in self.pts]}))
        old = sys.argv
        try:
            sys.argv = ['check', str(self.p), 'wide']
            with contextlib.redirect_stdout(io.StringIO()):
                exec(compile(CHECK, 'received-check', 'exec'), {})
        finally:
            sys.argv = old

    def testHealthy(self): self.check()
    def testOneStutterFails(self):
        self.pts.pop(600)
        with self.assertRaisesRegex(AssertionError, 'stutter'): self.check()
    def testRenderDropFails(self):
        self.write('app.log', 'dropped render=1 encoder=0')
        with self.assertRaisesRegex(AssertionError, 'drops'): self.check()
    def testLaterMicDriftFails(self):
        self.write('mic.log', '\n'.join(f'silence_end: {i+(.100 if i==12 else .002)}' for i in range(20)))
        with self.assertRaisesRegex(AssertionError, 'mic A/V'): self.check()
    def testMissingGameBeepFails(self):
        self.write('beep.log', '\n'.join(f'silence_end: {i+.002}' for i in range(20) if i!=12))
        with self.assertRaisesRegex(AssertionError, 'missing beep'): self.check()

if __name__ == '__main__': unittest.main()
