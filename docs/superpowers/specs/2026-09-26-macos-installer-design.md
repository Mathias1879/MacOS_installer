# MacOS_installer — Design Specification

**Date:** 2026-09-26
**Status:** Approved, pending implementation plan
**Repository:** `github.com/Mathias1879/MacOS_installer` (public)
**Local path:** `~/dev/MacOS_installer`

## Purpose

A macOS command-line tool that finds a requested version of macOS, downloads it
from Apple, and writes a bootable offline installer to a USB drive or other
external volume — guiding a first-time Mac user through every step.

Two audiences, one tool. A beginner gets a walkthrough that assumes no prior
knowledge of Terminal, disks, or booting. An experienced user passes `--brief`
and skips it.

## Goals

- Reach every macOS version Apple still distributes, including versions the
  host Mac cannot itself run.
- Never destroy data the user did not explicitly consent to destroy.
- Explain what is about to happen, what is happening, and what to do next, in
  language a teenager new to the Mac can follow.
- Ship as a public, open-source, Homebrew-installable tool with no paid
  service dependencies.

## Non-Goals

- No GUI. Terminal only.
- No Apple Developer signing or notarization in v1.
- No installation *onto* the host Mac. This tool creates media; it does not
  run installs.
- No hosted CI. All verification runs locally.

## Host Requirements

The **host** is the Mac running this tool. The **target** is the Mac the
finished media will boot. They are frequently different machines, and the
distinction matters throughout this document.

- Host must run macOS 13 Ventura or later. This is the floor for the Swift
  toolchain and concurrency features the implementation assumes, and it is
  comfortably above the 10.12.6 boundary that would otherwise complicate
  `createinstallmedia` invocation.
- Host must be Intel or Apple silicon; both are supported.
- Host requires an administrator account, for the two `sudo` operations.
- Host needs free disk space of roughly twice the installer size — once for
  the download, once for the assembled application.

The host's own model does **not** constrain which macOS versions can be
written. That is the entire reason the sucatalog source exists: an Apple
silicon host can produce Mojave media for a 2015 Intel target, which
`softwareupdate` alone would refuse to offer.

## Decisions

These were settled during design and are not open for reinterpretation during
implementation.

| Decision | Choice |
|---|---|
| Build vs. reuse | Original tool, own logic. No dependency on `mist-cli` or `gibMacOS`. |
| Interface | Interactive terminal UI, written in Swift. |
| Version sources | Apple sucatalog primary, `softwareupdate` fallback, local installers reused. |
| Writable versions | Mojave 10.14 through macOS 27 Golden Gate, independent of host model. |
| Safety | Hard refusal of internal/boot volumes, no override flag, typed-name confirmation. |
| Privilege | Run unprivileged; `sudo` only for the two operations that require it. |
| Distribution | Public repo, MIT, Homebrew tap. |
| Verification | Automated tests plus a manual boot-test release gate on real hardware. |

The single external dependency is `swift-argument-parser`.

## Verified Facts

Confirmed by direct probe on 2026-09-26, host macOS 27.0 (26A428), arm64.

- `softwareupdate --list-full-installers` returns only versions the host Mac
  model supports. On this Apple silicon host it returned macOS 27 down to
  Sequoia 15.7.7 — no Mojave, no Catalina. This is why the sucatalog path
  exists.
- The live catalog is
  `https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog`
  — HTTP 200, 7,045,040 bytes, 646 products.
- 19 products carry an `InstallAssistant.pkg`, spanning Big Sur 11 through
  macOS 27 Golden Gate. Golden Gate, Tahoe and Sequoia were all posted
  2026-09-14.
- Legacy products reference `InstallESDDmg.pkg` and use a different, chunked
  layout.
- Product entries contain **no** version, title or build. Each carries a
  `Distributions.English` URL pointing at a `.dist` file that must be fetched
  separately to learn, for example, "macOS Tahoe 26.7 (25G229)".
- `ServerMetadataURL` is absent on modern products; `ExtendedMetaInfo`
  identifies the SharedSupport package, e.g.
  `com.apple.pkg.InstallAssistant.macOSSequoia`.

### From Apple documentation

Sources: `support.apple.com/en-us/102662`, `support.apple.com/en-us/101578`
(published 2026-09-14).

- `createinstallmedia` erases the target volume itself, formatting it as Mac OS
  Extended (Journaled). No separate format step is required.
- `--applicationpath` is required only when the **host** Mac is running Sierra
  10.12.6 or earlier. It is a property of the machine creating the media, not
  of the version being written. Because this tool requires a modern host (see
  Host Requirements), that branch is unreachable and is **out of scope**. The
  command is otherwise uniform: `createinstallmedia --volume <path>`.
- The macOS password prompt displays no characters while typing.
- A TCC prompt — *"Terminal would like to access files on a removable volume"* —
  appears mid-run and must be accepted or the write fails.
- On success the volume is renamed to match the installer, e.g.
  `Install macOS Tahoe`.
- Apple's documented failure recoveries:
  - *"not a valid installer application"* → delete the installer, repair the
    startup disk with Disk Utility, download again.
  - *"command not found"* → wrong path, or installer not in `/Applications`
    under its expected name.
  - erase failure → erase manually in Disk Utility as Mac OS Extended
    (Journaled), then retry.
- Booting the finished media differs by target Mac:
  - Apple silicon: shut down, connect, press and hold the power button until
    startup options appear.
  - Intel: shut down, connect, power on and immediately hold Option (Alt).
  - T2 Macs additionally require Startup Security Utility to permit booting
    from external media.
- The target Mac must be online during installation so the installer can fetch
  model-specific firmware.
- An incompatible macOS/Mac pairing shows a circle with a line through it.
- Apple recommends a 32 GB drive; 16 GB suffices for older versions.

## Known Gap

The reassembly of legacy (Mojave, Catalina) chunked products into a working
`Install macOS X.app` is undocumented. Apple's `101578` covers
`createinstallmedia`, which presumes the `.app` already exists; it does not
describe producing one from `InstallESDDmg.pkg`, `InstallInfo.plist`,
`InstallAssistantAuto.pkg` and their siblings.

**This spec deliberately does not specify those steps.** The implementation
plan opens with a time-boxed spike against a real Catalina product to pin down
the mechanics. No code is written against the legacy path until the spike
reports.

## Architecture

Two targets. A thin executable holding all terminal I/O, and a library holding
all logic. Tests target the library; the executable stays thin enough not to
require coverage.

```
MacOS_installer/
├── Package.swift                    swift-argument-parser only
├── Sources/
│   ├── macos-installer/             executable — TUI, prompts, progress
│   │   ├── main.swift
│   │   ├── VersionPicker.swift
│   │   ├── VolumePicker.swift
│   │   ├── TargetMacPicker.swift
│   │   ├── WalkthroughPresenter.swift
│   │   └── ConfirmationPrompt.swift
│   └── MacOSInstallerKit/
│       ├── Catalog/
│       │   ├── SucatalogClient.swift
│       │   ├── DistributionParser.swift
│       │   └── CatalogURLResolver.swift
│       ├── Sources/
│       │   ├── InstallerSource.swift
│       │   ├── SucatalogSource.swift
│       │   ├── SoftwareUpdateSource.swift
│       │   └── LocalInstallerSource.swift
│       ├── Download/
│       │   ├── Downloader.swift
│       │   └── ChecksumVerifier.swift
│       ├── Assembly/
│       │   ├── AssemblyStrategy.swift
│       │   ├── InstallAssistantAssembler.swift
│       │   └── LegacyESDAssembler.swift
│       ├── Disks/
│       │   ├── DiskEnumerator.swift
│       │   └── VolumeGuard.swift
│       ├── Media/
│       │   └── InstallMediaWriter.swift
│       ├── Guidance/
│       │   ├── GuidanceStep.swift
│       │   ├── GuidanceCatalog.swift
│       │   └── InstructionExporter.swift
│       └── System/
│           └── CommandRunner.swift
├── Tests/MacOSInstallerKitTests/
│   └── Fixtures/                    recorded catalog + .dist snapshots
├── scripts/ci.sh
└── docs/manual-verification.md
```

### Key abstractions

**`CommandRunner`** — a protocol wrapping every subprocess invocation:
`softwareupdate`, `installer`, `hdiutil`, `diskutil`, `createinstallmedia`.
Tests inject a fake that returns canned output and records the exact argv it
was asked to run. This is what allows a destructive tool to be tested to 80%
coverage without touching a disk.

**`InstallerSource`** — three implementations (sucatalog, softwareupdate,
local) answering "what versions can I obtain?" and "produce the bytes."

**`AssemblyStrategy`** — two implementations (InstallAssistant, LegacyESD)
answering "turn these bytes into an `Install macOS X.app`." Legacy complexity
is confined to one file rather than spread as version checks throughout.

## Data Flow

```
                    ┌─ SucatalogSource ──── fetch catalog (7 MB)
                    │                       parse 646 products
                    │                       fetch N .dist files in parallel
                    │                       (cached 24h)
  launch ───────────┼─ SoftwareUpdateSource  softwareupdate
                    │                        --list-full-installers
                    │
                    └─ LocalInstallerSource  scan /Applications
                                             for Install macOS *.app

           merge + dedupe by (version, build)
           precedence: local > sucatalog > softwareupdate
                    │
                    ▼
     target Mac picker → BEFORE guidance → version picker
                    │
                    ▼
            disk picker → typed confirmation
                    │
                    ▼
     download (resumable) → checksum → assemble → re-resolve UUID
                    │
                    ▼
            sudo createinstallmedia  →  AFTER guidance + exported file
```

Catalog responses cache to `~/Library/Caches/macos-installer/` with a 24-hour
TTL. Local installers sort first so re-flashing a drive requires no download.

## Safety Model

`VolumeGuard` applies these rules. Refusals are absolute — there is no override
flag.

| Condition | Result |
|---|---|
| Disk reports internal via DiskArbitration | Refused, not listed |
| Volume is `/` or within the boot APFS container | Refused, not listed |
| Volume holds the download cache or assembled `.app` | Refused — would destroy its own input |
| Capacity < installer size + 2 GB headroom | Refused, shortfall shown |
| Volume is a Time Machine backup | Listed, flagged, requires typed name |

**Identity is the volume UUID, never the device node.** `/dev/disk4` is a
lease that changes across replug and reboot. The picker displays the device
node for recognizability, but the tool carries the UUID and re-resolves
UUID → current mount point in the instruction immediately preceding
`createinstallmedia`. If resolution fails, or resolves to a different device
than the user was shown, the operation aborts before anything is written.

**Confirmation** requires the user to type the volume's name exactly. A
yes/no prompt is not sufficient for an irreversible erase.

## Privilege Model

The tool refuses to run under `sudo`. Browsing, catalog fetching and the
multi-gigabyte download all run as the invoking user, so nothing in the cache
ends up root-owned.

Exactly two operations require root, and each shells out through `sudo` at the
moment it is needed, letting Terminal prompt for the password:

1. `installer -pkg <InstallAssistant.pkg> -target /`
2. `createinstallmedia --volume <path>`

No privileged helper, no XPC service, no notarization requirement.

## Guided Walkthrough

The walkthrough is the default; `--brief` disables it.

**The target Mac is asked for first.** The post-creation instructions depend
on the Mac being installed *onto*, not the host. Creating Mojave media on
Apple silicon for a 2015 Intel MacBook is the expected case, and the boot
procedures are entirely different. Options: Apple silicon / Intel 2018+ (T2) /
Intel 2017 or earlier / not sure — with help.

**Three stages:**

*Before* — what hardware to obtain (32 GB or larger), that the drive will be
completely erased, approximate duration, and that the target Mac must be
online during installation.

*During* — plain narration of each phase, with the two known surprises
pre-announced rather than explained after they confuse someone: the password
prompt shows no characters as you type, and a permission dialog about the
removable volume will appear and must be accepted.

*After* — the boot procedure for the selected target Mac only. No branching
for the reader to misparse. Includes the T2 Startup Security Utility
requirement where relevant, and the circle-with-a-line-through-it explanation.

**Instructions are exported to a file.** The after-steps are worthless in a
terminal the user is about to close before walking to another machine. On
success the tool writes `~/Desktop/How to use your <installer name>.md`
containing the boot steps for their chosen target, the T2 caveat if
applicable, and troubleshooting for a failed boot.

Guidance content is structured data in `Guidance/`, keyed by stage and target
architecture — not `print()` calls scattered through control flow. This keeps
it testable, editable and translatable independently of the logic.

## Error Handling

Every user-facing error states three things: what happened, what it means, and
what to do next.

```
 ✗ Couldn't erase the drive

   macOS refused to erase "SanDisk Ultra".
   This usually means the drive is damaged or
   formatted in a way macOS can't overwrite.

   To fix it:
     1. Open Disk Utility (Applications › Utilities)
     2. Select SanDisk Ultra in the sidebar
     3. Click Erase
     4. Set Format to "Mac OS Extended (Journaled)"
     5. Click Erase, then run this tool again

   Details saved to:
   ~/Library/Logs/macos-installer/2026-09-26.log
```

Apple's documented failures map onto typed errors carrying these recoveries.
Full technical context — exact argv, exit status, stderr — is written to
`~/Library/Logs/macos-installer/`. The terminal shows the human version.
Nothing is silently swallowed.

Specific handling:

- **Network failure** — downloads are resumable; retry with backoff, resume
  from the partial file.
- **Checksum mismatch** — discard, re-download once, then fail with the
  corrupt-download recovery.
- **UUID re-resolution failure** — abort before the destructive operation.
- **User cancels the sudo prompt** — clean exit, no partial state.
- **Interrupted write** — the media is in an unknown, non-bootable state. The
  tool says exactly that. It does not imply a retry may salvage it.

## Testing Strategy

Test-driven throughout: test first, observe failure, implement, refactor.

**Tier 1 — automated unit.** Catalog parsing against recorded fixtures, never
the live network. A snapshot of the 7 MB catalog and a representative set of
`.dist` files live in `Tests/Fixtures/`, making the suite offline,
deterministic and fast. Also: the `VolumeGuard` truth table with a case per
refusal rule, exact-argv assertions on command construction, guidance
rendering per target architecture, checksum verification, and download resume
logic.

**Tier 2 — automated integration.** The complete flow against
`FakeCommandRunner`. The critical assertions are negative:

- No destructive command is issued when `VolumeGuard` refuses.
- UUID re-resolution always immediately precedes the write.

**Tier 3 — manual release gate.** `docs/manual-verification.md`, executed
before each tag: real download, real USB drive, boot the produced media on the
pre-T2 Intel Mac (2012–2017) and on Apple silicon. The legacy path's
"supported" claim rests entirely on this checklist, making it a release
blocker rather than a suggestion.

Coverage target is 80%+ on `MacOSInstallerKit`. The executable target is
excluded as thin terminal I/O.

`scripts/ci.sh` runs build, test and coverage locally. No GitHub Actions,
consistent with the no-paid-services constraint.

## Release Criteria

- Automated suite green, `MacOSInstallerKit` coverage ≥ 80%.
- `docs/manual-verification.md` completed, including a successful boot on the
  pre-T2 Intel Mac.
- README documents the verified-hardware matrix honestly — anything not
  boot-tested is labelled as such.
- Homebrew tap formula installs and runs on a clean machine.
