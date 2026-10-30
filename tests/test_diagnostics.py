import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hp150.py"
spec = importlib.util.spec_from_file_location("hp150", SCRIPT)
hp150 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hp150)


class DiagnosticsTests(unittest.TestCase):
    def test_unverified_filter_architecture_is_not_ready(self):
        report = hp150.assess({
            "usb_connected": True,
            "queues": [{"name": "HP150", "model": "HP Officejet 150 Mobile L511",
                        "missing_filters": [], "filter_architectures": {}}],
            "scanners": [{"name": "HP Officejet 150 Mobile L511", "usbVendorID": 1008,
                          "usbProductID": 20498}],
            "scanner_enumeration_complete": True,
            "errors": [],
        })
        self.assertFalse(report["ready"])
        self.assertIn("filter_architecture_unverified", [item["code"] for item in report["findings"]])

    def test_incomplete_scanner_discovery_is_not_ready(self):
        report = hp150.assess({
            "usb_connected": True,
            "queues": [{"name": "HP150", "model": "HP Officejet 150 Mobile L511",
                        "missing_filters": [],
                        "filter_architectures": {"/opt/hp150/hpcups": ["arm64"]}}],
            "scanners": [{"name": "HP Officejet 150 Mobile L511", "usbVendorID": 1008,
                          "usbProductID": 20498}],
            "scanner_enumeration_complete": False,
            "errors": [],
        })
        self.assertFalse(report["ready"])
        self.assertIn("scanner_discovery_incomplete", [item["code"] for item in report["findings"]])

    def test_usb_identified_scanner_does_not_need_a_display_name(self):
        report = hp150.assess({
            "usb_connected": True,
            "queues": [{"name": "HP150", "model": "HP Officejet 150 Mobile L511",
                        "missing_filters": [],
                        "filter_architectures": {"/opt/hp150/hpcups": ["arm64"]}}],
            "scanners": [{"name": None, "usbVendorID": 1008, "usbProductID": 20498}],
            "scanner_enumeration_complete": True,
            "errors": [],
        })
        self.assertTrue(report["ready"])

    def test_intel_only_filter_is_not_ready_on_arm64(self):
        report = hp150.assess({
            "architecture": "arm64",
            "usb_connected": True,
            "queues": [{"name": "HP150", "model": "HP Officejet 150 Mobile L511",
                        "missing_filters": [],
                        "filter_architectures": {"/Library/Printers/hp/filter": ["x86_64"]}}],
            "scanners": [{"name": "HP Officejet 150 Mobile L511", "usbVendorID": 1008,
                          "usbProductID": 20498}],
            "scanner_enumeration_complete": True,
            "errors": [],
        })
        self.assertFalse(report["ready"])
        self.assertIn("filter_not_native_arm64", [item["code"] for item in report["findings"]])

    def test_connected_printer_with_generic_driver_is_not_ready(self):
        report = hp150.assess({
            "usb_connected": True,
            "queues": [{"name": "HP_Officejet_150", "model": "Generic PCL Laser Printer",
                        "missing_filters": []}],
            "scanners": [],
            "scanner_enumeration_complete": True,
            "errors": [],
        })
        self.assertFalse(report["ready"])
        self.assertIn("wrong_driver", [item["code"] for item in report["findings"]])
        self.assertIn("scanner_not_detected", [item["code"] for item in report["findings"]])

    def test_unnamed_scanner_does_not_hide_missing_hp_scanner(self):
        report = hp150.assess({
            "usb_connected": True,
            "queues": [{"name": "HP150", "model": "HP Officejet 150 Mobile L511",
                        "missing_filters": [],
                        "filter_architectures": {"/opt/hp150/hpcups": ["arm64"]}}],
            "scanners": [{"name": None}],
            "scanner_enumeration_complete": True,
            "errors": [],
        })
        self.assertFalse(report["ready"])
        self.assertEqual([item["code"] for item in report["findings"]], ["scanner_not_detected"])


if __name__ == "__main__":
    unittest.main()
