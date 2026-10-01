# MacOS_installer

A macOS command-line tool that finds a requested version of macOS, downloads
it from Apple, and writes a bootable offline installer to a USB drive or
other external volume.

This repository implements **version discovery** and **media creation**.

Version discovery finds every macOS version available to write, from three
sources —

- an `Install macOS *.app` already present on disk,
- `softwareupdate --list-full-installers` (filtered to what the host model
  supports), and
- Apple's public software update catalog (unfiltered, so it can reach
  versions the host itself could never run).

Media creation downloads the chosen version, verifies it against Apple's
published digest, assembles `Install macOS X.app`, and writes it to an
external drive with `createinstallmedia`.

That digest check is **integrity, not authenticity**: it confirms the
downloaded bytes were not truncated or corrupted in transit, not that they
came from Apple. The digest algorithm is SHA-1, which is collision-broken, so
it is not a substitute for a trust check. Authenticity instead comes from
`installer`, which verifies Apple's code signature on the package during
assembly and refuses to proceed if it does not check out.

### What is implemented

- Listing versions from all three sources (`list`).
- Writing media for **macOS Big Sur (11) and later**, when the release is
  downloadable as an `InstallAssistant.pkg` (the catalog or a local
  `Install macOS *.app`) — **implemented, but unproven.** `create` runs
  `createinstallmedia --nointeraction`, and that flag's behavior has never
  been verified against a real run: if `createinstallmedia` rejects it, or
  behaves differently than expected under it, the write path may not work at
  all. See "Verified on" below before relying on this for a real install.

### What does not work yet

- **Mojave and Catalina are listed but not writable.** They use a legacy,
  chunked ESD payload layout whose assembly is unimplemented — that's a
  later phase (see `docs/superpowers/plans/2026-09-26-media-creation.md`).
  `create` will list these versions but fails explicitly, rather than
  silently, if you try to write one.
- **A `softwareUpdate`-only release cannot be downloaded directly.** If
  `list` shows a version with no local or catalog payload, fetch it first
  with `softwareupdate --fetch-full-installer`, then re-run `create` — it
  will pick up the local copy.

### Safety model

- `create` **ERASES the target volume.** There is no "preview" mode once you
  confirm.
- Internal disks and the current boot volume (including its sealed system
  snapshot) are **never offered as targets, with no override flag.** This is
  an absolute refusal by design, not a default that can be bypassed.
- A typed, exact confirmation of the target volume's name is required before
  anything is erased (unless `--yes` is passed for scripted/trusted use).

### Verified on

**Not yet verified — see [`docs/manual-verification.md`](docs/manual-verification.md).**

183 automated tests cover the logic, but nothing has been booted from real
media yet: no USB stick has been written and tested end to end, on any Mac,
of any era. Do not treat this tool as proven to produce bootable media until
that checklist has been run and its results recorded.

## Requirements

- macOS 13 (Ventura) or later
- Swift 6 toolchain (ships with Xcode 16+, or via Command Line Tools)

## Building and running

```bash
swift build
swift run macos-installer list            # every version, including Apple's full catalog
swift run macos-installer list --offline  # skip the network catalog; softwareupdate + local only

# Write bootable media. THIS ERASES THE TARGET VOLUME.
swift run macos-installer create --version 15.8.1 --volume "MyUSBDrive"

# Omit --version or --volume to see the available options instead of guessing:
swift run macos-installer create
```

`create` will:

1. ask you to type the target volume's exact name to confirm, then
2. download `InstallAssistant.pkg` for the requested version (resuming an
   interrupted download rather than restarting it),
3. verify it against Apple's published digest,
4. run `installer` to assemble `Install macOS X.app` (admin password
   required), then
5. run `createinstallmedia --volume <mount point> --nointeraction` as root.

**Confirmation happens first, before anything is downloaded or prepared.**
Once you type the volume's name, the erase at step 5 is already consented to
and will run unattended at the end of a potentially 30+ minute download and
assembly, with no further prompt. Do not assume that because the download is
still running nothing has been committed yet, and do not swap or unplug
drives during that window — the target was already chosen and confirmed.

Internal volumes and the current boot volume are never offered as targets —
there is no flag to override this.

## Running tests

Use the project's test script rather than calling `swift test` directly:

```bash
./scripts/test.sh
```

### Why not bare `swift test`?

On a machine with only the Command Line Tools installed (no full Xcode), the
Swift Testing macro plugin used by `import Testing` and `@Test` lives at
`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` — a
subdirectory SwiftPM does not search on its own. Running `swift test` there
fails with a cryptic error:

```
error: plugin for module 'TestingMacros' not found
```

`scripts/test.sh` passes the required `-plugin-path` flag to work around
this, guarded behind a check for that directory so it stays inert on a
machine with full Xcode installed (where the plugin is found normally). Any
extra arguments are forwarded to `swift test`, e.g.:

```bash
./scripts/test.sh --filter ReleaseTableFormatterTests
```

## Local CI

There is no hosted CI — everything runs on your machine:

```bash
./scripts/ci.sh
```

This builds the package, runs the full test suite with code coverage
enabled, and fails if line coverage for `MacOSInstallerKit` drops below 80%.
