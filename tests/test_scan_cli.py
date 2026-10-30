from pathlib import Path
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/scan-native.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("scan_native", SCRIPT)
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class ScanCLITests(unittest.TestCase):
    def test_timeout_stops_descendants_that_keep_output_pipes_open(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "descendant.pid"
            child = (
                "import signal,time; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(60)"
            )
            parent = (
                "import subprocess,sys; from pathlib import Path; "
                "p=subprocess.Popen([sys.executable,'-c',sys.argv[2]]); "
                "Path(sys.argv[1]).write_text(str(p.pid))"
            )
            driver = (
                "import importlib.util,os,sys; "
                "sys.path.insert(0,sys.argv[1]); "
                "s=importlib.util.spec_from_file_location('scanner',sys.argv[2]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "m.ScannerProcess().run([sys.executable,'-c',sys.argv[3],sys.argv[4],sys.argv[5]],os.environ.copy(),0.5)"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", driver, str(SCRIPT.parent), str(SCRIPT), parent, str(pidfile), child],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                _, stderr = process.communicate(timeout=9)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("Scanner timed out", stderr)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                if pidfile.exists():
                    try:
                        os.kill(int(pidfile.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_existing_output_is_preserved_before_any_device_access(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "original.png"
            output.write_bytes(b"existing user file")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--runtime", directory, "--output", str(output)],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stderr)
            self.assertEqual(output.read_bytes(), b"existing user file")

    def test_only_exact_usb_model_is_selected_and_ambiguity_is_rejected(self):
        hp = "hpaio:/usb/Officejet_150_Mobile_L511?serial=TEST1"
        candidates = "\n".join([
            "hpaio:/net/Officejet_150_Mobile_L511?ip=192.0.2.1",
            "hpaio:/usb/Officejet_100_Mobile_L411?serial=TEST2", hp,
            "hpaio://elsewhere/usb/Officejet_150_Mobile_L511?serial=TEST5",
            "hpaio:/usb/Officejet_150_Mobile_L511_extra?serial=TEST3",
        ])
        self.assertEqual(scanner.select_device(candidates), hp)
        with self.assertRaisesRegex(ValueError, "Multiple"):
            scanner.select_device(hp + "\n" + hp.replace("TEST1", "TEST4"))

    def test_a_valid_but_cropped_a4_scan_is_rejected(self):
        image = {"width": 2559, "height": 3279, "dpi_x": 300, "dpi_y": 300}
        with self.assertRaisesRegex(ValueError, "page size"):
            scanner.check_page(image, "A4", 300)
        image.update(width=2480, height=3507)
        scanner.check_page(image, "A4", 300)

    def test_adf_length_variation_is_bounded_to_two_millimeters(self):
        # This feeder returned 3492 rows for A4 at 300 dpi (1.34 mm short).
        image = {"width": 2480, "height": 3492, "dpi_x": 300, "dpi_y": 300}
        scanner.check_page(image, "A4", 300)
        image["height"] = 3480  # More than 2 mm missing is still an error.
        with self.assertRaisesRegex(ValueError, "page size"):
            scanner.check_page(image, "A4", 300)
        image.update(width=2465, height=3507)  # Width is not measured by feeding.
        with self.assertRaisesRegex(ValueError, "page size"):
            scanner.check_page(image, "A4", 300)


if __name__ == "__main__":
    unittest.main()
