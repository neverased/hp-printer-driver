# HP Officejet 150 on Apple Silicon

Native USB printing and scanning tools for **HP Officejet 150 Mobile L511** on
macOS. **No Rosetta.** Developed on macOS 27.2, ARM64.

Printing uses a locally compiled HPLIP `hpcups` renderer and the original model
PPD. The installed driver has working model options; the user confirmed correct
physical output from both the initial color test and a normal PDF job through the
macOS print queue.

Scanning uses native SANE/HPLIP and a small **HP150 Scanner** macOS app. A physical
A4 color scan at 300 dpi passed through the app, including saving and opening the
PNG. Visual inspection confirmed all test content and the complete 15 mm border.
The output is 2480 × 3492 pixels; the feeder ends about 1.34 mm short of nominal
A4 height, with a normal device end-of-page signal and no read error. The original
HP Image Capture module was tried twice and returned `CANCEL PRESSED` without
saving an image. See
[compatibility and evidence](docs/compatibility.md).

## Use the scanner app

On the development Mac, the app is installed in the user's Applications folder:

```sh
open "$HOME/Applications/HP150 Scanner.app"
```

1. Connect the printer by USB and close Image Capture and other scanner clients.
2. Insert one original into the scanner.
3. Choose color or grayscale, resolution and paper size. Defaults are color,
   300 dpi and A4.
4. Click **Skanuj…**, choose a new PNG filename and wait for the scan to finish.
5. Use **Otwórz** or **Pokaż w Finderze** to inspect the result.

**Anuluj** stops the scan; closing the app also cancels an active scan before
exiting. Existing output files are never overwritten. Another scan from this app
or the public CLI is blocked while one is running. Reload the original before
retrying a cancelled or failed acquisition.

This is a local app build, not a standalone installer. Its bundled `runtime.json`
points to `.build/hplip-native-scan` in this checkout. Keep that directory and the
native Homebrew libraries it uses in place. The app bundles its Python scripts,
but uses an installed native Python 3.9 or newer: `/opt/homebrew/bin/python3` when
available, otherwise `/usr/bin/python3`. It explicitly launches Python as ARM64.
Moving the checkout or changing these dependencies can require a rebuild.

## Build the scanner and app

Requirements: Apple Silicon, Xcode tools with Swift 6, Python 3 with development
headers, `pkg-config`, and existing native `libusb`, `jpeg-turbo`, `libpng` and
`libtiff` development packages. The scripts do not install Homebrew packages,
modify system drivers or access the scanner during a build.

For a fresh checkout:

```sh
bash scripts/build-sane.sh
bash scripts/build-scanner-app.sh
open ".build/HP150 Scanner.app"
```

`build-sane.sh` verifies pinned SANE 1.4.0 and HPLIP 3.26.6 source hashes, applies
the macOS compiler changes and the two patches in `patches/`, and records native
binary architectures, dependencies and hashes in its manifest. The patches use
the device's ADF-specific height and fix SANE's PNG output for unknown or
incomplete frame lengths.

The scanner build refuses an existing output directory. To verify a fresh build
without changing the current runtime, use
`bash scripts/build-sane.sh --output "$PWD/.build/sane-rebuild"`. The app builder
continues to use `.build/hplip-native-scan`; the CLI can select another runtime
explicitly. Build paths must not contain whitespace.

The app is signed ad hoc for local use. `script/build_and_run.sh` gracefully
closes the existing app, rebuilds it and launches the bundle; this is also the
Codex **Run** action. `--verify` checks launch, without starting a scan.

## Scan from the command line

This command performs a physical scan. Insert a sheet first and choose a filename
that does not exist:

```sh
mkdir -p reports
python3 scripts/scan-native.py \
  --runtime "$PWD/.build/hplip-native-scan" \
  --output "$PWD/reports/scan.png" \
  --dpi 300 --mode Color --paper A4
```

Supported settings are `Color` or `Gray`, 75/100/150/200/300/600 dpi, and A4,
Letter or Legal. The wrapper selects the exact USB model, enables only the
`hpaio` backend, and checks PNG completeness, page dimensions, resolution and
color mode before publishing the file. Success prints JSON with the output path
and dimensions. Errors go to stderr; cancellation returns exit code 130.
Page width must match within three pixels. Length allows up to 2 mm of feeder
variation; larger discrepancies are rejected. The image is never stretched or
padded to hide missing pixels. Other settings are exposed but have not all been
physically verified; Color/300 dpi/A4 is the tested configuration.

## Build and install printing

The print build needs native `jpeg-turbo` development files and `pkg-config`.
JPEG is linked statically; the installed renderer uses only macOS libraries.
Review the installation script before running it. Installation requires
administrator authentication.

```sh
bash scripts/build-hpcups.sh
bash scripts/install-native-print.sh --check
sudo bash scripts/install-native-print.sh
python3 scripts/configure-queues.py
python3 scripts/configure-queues.py --apply
```

Queue configuration backs up the existing Officejet 150 USB PPDs under `reports/`,
then applies the model driver and A4. It preserves their USB connections, the
default printer and other printers, and refuses queues with unfinished jobs.
This version expects an existing Officejet 150 USB queue. The filter, PPD,
manifest and licenses are installed under `/Library/Printers/HP150`.

To restore a queue's previous driver, use `lpadmin -p QUEUE -P BACKUP.ppd` with its
saved PPD. Remove only files created by this project after restoring queues;
preserve unrelated printers and shared HP directories.

## Verification and diagnostics

```sh
python3 -m unittest discover -s tests -v
bash tests/run-scanner-process-tests.sh
python3 scripts/validate_scan.py reports/scan.png
python3 scripts/hp150.py
mkdir -p reports
xcrun swift scripts/make-test-page.swift reports/print-test.pdf
```

For a print check, load A4 and print the PDF from Preview using the HP queue,
color, normal quality and 100% scale. Inspect colors, text and margins on paper.
For a scan check, inspect the complete original, including its lower edge.
The current verification includes 20 Python tests and five offline Swift process
checks, including timeout cleanup and cancellation after successful publication.

`hp150.py --scan` is an optional read-only **Image Capture** diagnostic for the
original HP module; it does not test the SANE app or prove successful acquisition.
Run discovery diagnostics only while the device is idle. Diagnostics omit printer
serial numbers. Generated builds, source archives and reports stay in ignored
`.build/`, `.cache/` and `reports/` directories.

## Original HP scanner package: optional investigation

The retained tools can download, inspect and stage the original HP package:

```sh
bash scripts/prepare-driver.sh
bash scripts/stage-native-scanner.sh
```

The approximately 320 MB download has a pinned SHA-256 hash. Staging verifies HP
signatures, notarization, ARM64 slices and loader dependencies. It refuses an
existing staging directory; use `--output /path/to/new-directory` for another
inspection. Neither command installs or launches the complete HP installer.

`scripts/install-native-scanner.sh` remains available for the original HP Image
Capture integration, but is **not required by the SANE app**. On this Mac it was
installed and investigated; both physical acquisition attempts failed without an
image. The installed paths are:

- `/Library/Image Capture/Devices/HP Scanner 3.app`
- `/Library/Printers/hp/Frameworks/HPDM.framework`
- `/Library/Printers/hp/hpio/HPIOPrinterClassDriver.plugin` (transport symlink)
- `/Library/Printers/hp/hp150-native-scanner-manifest.txt` (created-path manifest)

The original bundles remain intact to preserve HP signatures. Their verified USB
execution path is ARM64, although unused auxiliary resources include Intel-only
binaries. No HP proprietary binaries are committed or redistributed. If removing
this optional integration, close Image Capture and consult the created-path
manifest; do not remove shared HP parent directories or unrelated drivers.

This is a community compatibility setup, not an HP-supported macOS 27 driver.
HPLIP, SANE and JPEG licenses are retained with their builds. Hardware limits
remain: manual duplex, single-sheet scanning and no scanning over Bluetooth.
HP Utility, ink-level/maintenance functions, scan-to-computer buttons and PDF
output are not included or verified by this setup.
