# HP Officejet 150 Mobile L511 — macOS USB compatibility

Investigation date: 2026-10-30. Target: macOS 27.2, Apple Silicon, USB.
The user explicitly requires **no Rosetta**.

## Current result

| Path | Evidence |
|---|---|
| Native HPLIP printing | Installed; user confirmed correct physical color test and normal PDF output through the macOS queue. |
| Native SANE scanning | A4 Color/300 dpi acquired as a valid 2480 × 3492 PNG after geometry and PNG corrections. All test content and the full 15 mm border are visible; normal device end-of-page, no read-error event. |
| HP150 Scanner app | ARM64 build and ad hoc signature verified. Physical scan, Save dialog, success display and Open in Preview passed from the installed user Applications copy; five offline process checks also passed. |
| Original HP Image Capture integration | ARM64 discovery and initialization passed. Two physical acquisitions returned `CRErrorDomain Code=13`, `CANCEL PRESSED`, with no saved image. |

The primary scan workflow is now the native SANE app or `scripts/scan-native.py`.
The original HP staging and installation tools are retained as an optional record
of the investigation; the app does not require those proprietary components.

## Initial state on this Mac

- USB detected `HP Officejet 150 Mobile L511`, vendor `03f0`, product `5012`.
- Two existing USB queues used `Generic PCL Laser Printer` and `HP DeskJet Series`.
  The generic laser PPD advertised monochrome output, A3 and a duplexer, which do
  not describe this model. Its `rastertohp` filter existed.
- No HP Image Capture device module was installed; native scanner discovery
  initially returned no scanners.
- The Intel execution probe failed with `Bad CPU type in executable`; the Rosetta
  package receipt was absent. No Rosetta installation was performed.
- System driver installation required the user's administrator authentication.

## Hardware and upstream support

The printer uses PCL 3 GUI. USB and Bluetooth are supported, duplex is manual and
borderless printing is limited to 10 × 15 cm. Bluetooth supports printing only;
scan-to-computer requires USB. Sources: [HP specifications](https://support.hp.com/us-en/product/product-specs/hp-officejet-150-mobile-all-in-one-printer-series---l511/model/4231412),
[HP user guide](https://h10032.www1.hp.com/ctg/Manual/c03245669.pdf), page 9.

HP lists HPLIP support since 3.12.10: full color printing, USB scanning and no
proprietary plug-in. This describes Linux support; the macOS port has been tested
separately here. [HP supported-device table](https://developers.hp.com/hp-linux-imaging-and-printing/supported_devices/index).

HPLIP 3.26.6 contains `officejet_150_mobile_l511`, its `hpcups` PPD and SCL scanning
through `hpaio`/`hpmud`. The model entry lists USB PID `4912`; the attached unit
reports `5012`. Native hpmud nevertheless discovered and opened the exact model
successfully, without a PID override. A PPD alone cannot render PCL 3 GUI or
implement scanning. [HPLIP source](https://sourceforge.net/projects/hplip/files/hplip/3.26.6/hplip-3.26.6.tar.gz/download).

## Native printing

`scripts/build-hpcups.sh` builds HPLIP 3.26.6 using native clang. Source SHA-256:
`5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3`.
The macOS changes fix case-insensitive header/object name collisions, skip Linux
`malloc.h`, disable an optional ImageProcessor used by another printer family,
and link native JPEG statically. The ARM64-only renderer links only system
`libcups`, `libz`, `libc++` and `libSystem` at runtime.

The user authenticated installation under `/Library/Printers/HP150`. Both existing
HP USB queues now use the exact model PPD, absolute native filter path and A4.
The Epson default printer was preserved. Original PPDs were backed up in ignored
`reports/`. The model PPD exposes color/grayscale, paper sizes, media types and
quality settings; it does not advertise an automatic duplexer.

The initial pre-rendered PCL test produced a correct physical color page. After
installation, a complete `cupsfilter` PDF → raster → PCL3GUI check passed, and the
user confirmed the physical result of a normal PDF job through the configured
CUPS queue. A completed spooler job alone was not treated as sufficient evidence.

## Native SANE implementation

`scripts/build-sane.sh` reproducibly builds local ARM64 SANE 1.4.0 and HPLIP 3.26.6
without system installation or USB access. It refuses to overwrite an existing
build and supports `--output NEW-DIRECTORY`. SANE source SHA-256:
`f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72`.
[Official SANE release archive](https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-1.4.0.tar.gz).

The runtime consists of `scanimage`, the SANE loader, `libsane-hpaio.1.so`,
`libhpmud`, `libhpip` and `libhpipp`. Network support is disabled in HPLIP; the
scan wrapper enables only `hpaio`, selecting exactly one Officejet 150 USB device.
The optional SANE test backend is used for offline tests and is not enabled in
the hardware scan configuration. An offline native `dlopen(RTLD_NOW)` plus
`sane_hpaio_init/exit` check passed before USB testing.

Compiler adaptations replace `CFPlugInCOM.h` with `CFBase.h` to avoid an `ULONG`
conflict, add the missing Orblite declarations, and include `unistd.h`/`dlfcn.h`
where required. Two tracked behavioral patches are applied:

- `patches/hplip-adf-only-y-extent.patch`: use a successful positive ADF-specific
  Y maximum on ADF-only devices, falling back to the generic maximum otherwise.
- `patches/sane-1.4.0-png-completeness.patch`: correctly encode buffered PNG data
  when the frame length is unknown, and reject incomplete known-length frames.

### A4 crop diagnosis

The first physical SANE command reported exit 0 and produced a partially viewable
2559 × 3279 color image at 300 dpi, but its PNG stream was incomplete. It was not
accepted as a successful saved scan. The options limited height to 277.707 mm,
which cropped the bottom of A4. Read-only SCL inquiries established the cause:

| Capability | Device response | Converted value |
|---|---:|---:|
| Device coordinate units | 300 per inch | — |
| Generic X maximum | 2560 | 216.747 mm |
| Generic Y maximum | 3280 | 277.707 mm |
| Flatbed Y maximum | 0 | No flatbed |
| ADF Y maximum | 4210 | 356.447 mm |

The original backend queried only the generic Y maximum, despite defining an
ADF-specific inquiry. The patch uses the device's reported ADF capability; it
does not force a model name or paper dimension. The regression check changed from
failing at 277.707 mm to passing at 356.447 mm, and explicit 210 × 297 mm options
were accepted. `Unknown` frame length alone would not remove the crop: SCL still
receives the selected Y extent.

### PNG completeness and public wrapper

Investigation also found that SANE's PNG frontend mishandled unknown frame
lengths and could publish invalid incomplete output. The PNG patch and virtual
scanner tests cover this independently of the hardware.

`scripts/scan-native.py` requests an explicit A4/Letter/Legal area with unknown
frame length. Before atomically publishing a new file it checks PNG structure,
CRC, decompression, row completeness, page dimensions, resolution and color mode.
It refuses existing outputs, locks scanning per user, and propagates cancellation
to the native process group. Failures and cancellations do not publish an image.
Device serials are omitted from reported diagnostics. Width allows three pixels
for integer rounding; length allows up to 2 mm of feeder variation. Larger
discrepancies fail. No image resizing or synthetic padding is used.

### Final physical GUI verification

The first corrected GUI scan produced valid PNG data at 2480 × 3492 pixels, but
the initial three-pixel height check rejected it: this is about 1.34 mm shorter
than nominal A4. A repeat at Color/300 dpi/A4, with a bounded 2 mm length tolerance,
successfully saved `reports/hp150-full-a4-300dpi.png` from the installed app.
Validation confirmed RGB8, complete rows, valid CRCs and zlib termination, and
299.9994 dpi metadata. Visual inspection confirmed all text, color blocks,
grayscale and the entire 15 mm border, including the bottom edge.

A temporary logging-only backend probe recorded a normal end-of-page event
(`result=0x4001a`, raw black/color row fields both 877) and no read-error event.
The raw device row fields are not treated as output-pixel dimensions. This
distinguishes the observed finish from HPLIP's fallback that treats some transport
errors as EOF. Source, backend and build artifacts were then restored byte for
byte, with SHA-256 checks. The valid scan is 2480 × 3492, not a padded 2480 × 3508;
edge-to-edge capture of the nominal sheet dimensions is not claimed.

The app displayed success and its **Otwórz** action opened the saved image in
Preview. This verifies the real GUI → CLI → USB → PNG workflow. Twenty Python
tests and five offline Swift process tests passed, including incomplete output,
mode mismatch, descendant cleanup, concurrent scans and late cancellation.

## Native macOS app and deployment limits

`app/` implements a Polish SwiftUI window with color/grayscale, six resolutions,
paper selection, a native PNG save dialog, progress, cancellation, and Open/Reveal
actions. Defaults are Color, 300 dpi and A4. The app rejects overlapping scans;
closing it cancels an active scan before exit. Offline process tests passed for
successful results, error propagation and redaction, overlap rejection and
cancellation. The app was compiled under Swift 6 strict concurrency as ARM64-only
and its ad hoc signature verified.

`scripts/build-scanner-app.sh` creates `.build/HP150 Scanner.app` and bundles
`scan-native.py` and `validate_scan.py`. Its `runtime.json` contains the absolute
path of the local scanner runtime and selected native Python executable. It
prefers `/opt/homebrew/bin/python3`, falling back to `/usr/bin/python3` when that
provides native Python 3.9 or newer, and invokes Python with `arch -arm64`.
The verified app was also copied to `~/Applications/HP150 Scanner.app`; its
signature was rechecked there. Both copies use the same local runtime.

The scanner runtime dynamically uses existing native Homebrew libraries,
including libusb, JPEG, PNG and TIFF. Development headers are required to build;
the configured runtime paths must remain available afterward. This is a local
checkout-based app, not a self-contained or notarized distribution. Rebuilding is
needed if those paths cease to exist. No scanner runtime is installed into system
locations. `script/build_and_run.sh` and the Codex Run action rebuild and launch
the app; `scripts/build-scanner-app.sh` builds without launching or scanning.

## Original HP package investigation

Apple's older HP 5.1.1 package explicitly excludes macOS 12 and newer.
[Apple compatibility statement](https://support.apple.com/en-sg/106385).
HP documents Easy Admin for obtaining packages without connecting a printer.
[HP Easy Admin documentation](https://support.hp.com/ee-en/document/c06164609).

The HP software catalogue at `https://h20614.www2.hp.com/ediags/solutions/software/v3`
returned Essentials R 5.20.0.1 for this model with macOS 26, and `NOT SUPPORTED`
for macOS 27.2. The original download is
[hp-printer-essentials-R-5_20_0_1.pkg](https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials/macOS26/hp-printer-essentials-R-5_20_0_1.pkg).

- Size: 319,948,669 bytes.
- SHA-256: `22d7c4029fbfe335fb63528bdadd02c0a471017e159c472c0c8d276caf78db2f`.
- HP Inc. signature, team `6HB5Y2QTA3`, and notarization checks passed.
- Exact L511 model data and USB PID `5012` are present.
- The Officejet print executable is Intel-only and was not used.
- HP Scanner 3 and its USB dependency path contain ARM64 code; unused auxiliary
  resources include Intel-only binaries. Bundles were preserved intact.

The user authenticated installation of HP Scanner 3, HPDM and the original
transport symlink. A runtime sample confirmed **Code Type: ARM64**. After closing
Image Capture and restarting the user's previously running `icdd`, native
scanner discovery and initialization passed. Image Capture exposed color, A4 and
75/100/200/300/600 dpi.

The first Color/A4/300 dpi acquisition fed the sheet, then returned
`CRErrorDomain Code=13`, `CANCEL PRESSED`, without an image. A discovery probe ran
concurrently on that attempt. A second controlled acquisition, with a reloaded
sheet and no concurrent discovery, failed with the same error and no file. Thus
concurrent discovery did not explain the repeated failure. These components are
not the primary scan workflow, and discovery success is not presented as working
acquisition.

`prepare-driver.sh` and `stage-native-scanner.sh` retain download/signature/loader
inspection. `install-native-scanner.sh` remains an optional experimental installer;
it is not required by the SANE app. The created-path manifest supports targeted
removal without deleting shared HP directories. No proprietary HP binaries are
committed or redistributed.

## Remaining verification and scope

Color/300 dpi/A4 printing and scanning are physically verified as described above.
Other scan resolutions, grayscale, Letter/Legal and physical cancellation have
not all been verified on paper. No claim is made about HP Utility, ink or maintenance functions,
scan-to-computer buttons, Bluetooth scanning or PDF output. This remains a
community compatibility setup, not an HP-supported macOS 27 driver.
