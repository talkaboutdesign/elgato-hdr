import unittest
from stream_checks import check_timing, check_drops, check_actions

class StreamChecksTests(unittest.TestCase):
    def test_arrival_jitter_is_not_a_lost_frame(self):
        check_timing([0, 1, 1.029, 1.045], 60)
        for gap in [1.9 / 60, 2 / 60]:
            with self.assertRaises(AssertionError): check_timing([0, 1, 1 + gap + 1e-10], 60)
        with self.assertRaises(AssertionError): check_timing([0, 1, 1.017], 59.49)
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
