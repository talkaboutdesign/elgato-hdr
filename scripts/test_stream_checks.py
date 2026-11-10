import unittest
from stream_checks import check_timing, check_drops, check_actions, lane_frame_rate

class StreamChecksTests(unittest.TestCase):
    def test_arrival_jitter_is_not_a_lost_frame(self):
        check_timing([0, 1, 1.029, 1.045], 60)
        for gap in [1.9 / 60, 2 / 60]:
            with self.assertRaises(AssertionError): check_timing([0, 1, 1 + gap + 1e-10], 60)
        with self.assertRaises(AssertionError): check_timing([0, 1, 1.017], 59.49)
    def test_half_rate_timing_uses_lane_rate(self):
        check_timing([0, 1, 1.034, 1.067], 30, fps=30)
        with self.assertRaises(AssertionError): check_timing([0, 1, 1.067], 30, fps=30)
        with self.assertRaises(AssertionError): check_timing([0, 1, 1.034, 1.067], 30, fps=60)
    def test_lane_rate_ignores_unchanged_stream_headers(self):
        log = 'metadata fps=60\nVertical stream at 30 fps — the video encoder is at capacity\n'
        self.assertEqual(lane_frame_rate(log, 'vertical'), 30)
        self.assertEqual(lane_frame_rate(log, 'wide'), 60)
        log += 'Horizontal stream at 30 fps — the video encoder is at capacity\n'
        self.assertEqual(lane_frame_rate(log, 'wide'), 30)
        log += 'Vertical stream restored to 60 fps\n'
        self.assertEqual(lane_frame_rate(log, 'vertical'), 60)
        self.assertEqual(lane_frame_rate(log, 'wide'), 30)
    def test_all_drop_counters(self):
        base = 'dropped render=0 encoder=0 queueRejected=0 inFlightRejected=0'
        check_drops(base)
        for key in ['render', 'encoder', 'queueRejected', 'inFlightRejected']:
            with self.assertRaises(AssertionError): check_drops(base.replace(key + '=0', key + '=1'))
    def test_actions_cannot_pass_vacuously(self):
        for script, actual in [('invalid', []), ('8:next', []), ('8:next', ['punch'])]:
            with self.assertRaises(AssertionError): check_actions(script, actual)
        check_actions('8:next,12:marker', ['next', 'marker'])

if __name__ == '__main__': unittest.main()
