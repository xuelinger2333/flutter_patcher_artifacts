from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pair_device import connected_devices


class DeviceTests(unittest.TestCase):
    def test_no_devices_is_a_real_skip(self):
        self.assertEqual(connected_devices('List of devices attached\n\n'), [])

    def test_authorized_device_detected(self):
        self.assertEqual(connected_devices('List of devices attached\nserial-1\tdevice\n'), ['serial-1'])

    def test_offline_or_unauthorized_is_not_reported_as_no_device(self):
        for status in ('offline', 'unauthorized'):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'cannot be skipped'):
                connected_devices(f'List of devices attached\nserial-1\t{status}\n')


if __name__ == '__main__':
    unittest.main()
