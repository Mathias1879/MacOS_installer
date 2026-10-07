# MacOS_installer

A macOS command-line tool that finds a requested version of macOS, downloads
it from Apple, and writes a bootable offline installer to a USB drive or
other external volume.

> **Picking this up after a break, or on a different machine?** Start with
> [`docs/HANDOFF.md`](docs/HANDOFF.md) — current state, what to do next, and the
> environment gotchas that will otherwise cost you an hour.

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
- A guided walkthrough around that write, and structured, plain-language
  error messages when something fails. Neither changes what `create` does —
  they explain it. See "Guided walkthrough" below. **Explaining the tool well
  and the tool actually working are different claims; this plan only touched
  the first one.**

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

### Guided walkthrough

Unless `--brief` is passed, `create` first asks **which Mac will boot the
finished installer** — not necessarily the Mac running this tool. The three
choices are a Mac with Apple silicon, an Intel Mac with a T2 security chip,
and an Intel Mac without one. This matters because the three boot in
different ways, and only the T2 case needs an extra step (changing Startup
Security Utility) before the drive will even appear at startup. Typing `?`
instead of a number prints help for figuring out which one you have, without
costing you one of your answer attempts.

Around the actual work, three guidance stages print:

- **Before** — what you need (a 32 GB+ drive) and what to expect (an erase,
  a 30–60 minute wait, keep the drive plugged in and the Mac awake). This
  stage ends with "Plug the drive in now, then press Return." and waits —
  the list of mounted drives is taken only *after* you press Return, so a
  drive you plug in right at that prompt is still picked up. Skipped when
  stdin is not a terminal (piped input, CI), since nothing there could press
  Return.
- **During** — what's happening at each step, including the two things that
  look like problems but aren't: the macOS password prompt that shows no
  characters as you type, and a "Terminal would like to access files on a
  removable volume" permission dialog. Both are pre-announced here, before
  they happen, specifically so neither is mistaken for a hang or a failure.
- **After** — how to boot the specific Mac you named at the start. Only that
  Mac's boot method is shown; an Apple silicon Mac and an Intel Mac do not
  see each other's steps.

After a successful write, the After-stage text is also saved to
`~/Desktop/How to use your <installer name> installer (<target>).md` —
because the Mac showing this terminal window is frequently the one about to
be wiped, and a printed stage you've already scrolled past is not something
you can carry to the other machine. A failure to save that file does not
fail the run; the steps were already printed above.

`--brief` skips the target-Mac question and all three stages — `create`
prints only what's strictly necessary, the same as before this plan.

**The real order of operations**, because it is easy to get backwards:
target-Mac question → look up available versions → pick one → Before stage
→ **wait for you to press Return** (skipped on a non-terminal stdin) →
list mounted drives → safety checks → **you type the drive's name to
confirm the erase** → During stage → download (8–60 minutes) → digest
check → the installer app is installed (this is where macOS asks for your
password) → **the drive is erased and written** → After stage → the
instructions file is saved.

The typed confirmation happens **before** the long download even starts.
The erase itself happens **unattended, at the very end**, after everything
else has already succeeded, with no further prompt. Do not read "the
download is still running" as "nothing has happened yet" — the drive was
already chosen and consented to several steps earlier. Do not swap or
unplug drives during that window on the belief that the erase hasn't
happened; by the time the stick is actually erased, there's no second
confirmation to catch a mistake.

When something fails, the message you see has three parts — what happened,
what it probably means, and what to try next — and the technical detail
behind it (the exact command, exit code, and output) is written to
`~/Library/Logs/macos-installer/<date>.log` rather than dumped to the
terminal. Downloads retry automatically with backoff on a dropped
connection, and a digest mismatch triggers exactly one automatic
re-download before giving up.

### Verified on

**Not yet verified — see [`docs/manual-verification.md`](docs/manual-verification.md).**

296 automated tests cover the logic, but nothing has been booted from real
media yet: no USB stick has been written and tested end to end, on any Mac,
of any era. That remains true no matter how complete the guided walkthrough
above looks — a tool that explains its steps clearly and a tool that produces
working media are different claims, and only the first one has been checked.
Do not treat this tool as proven to produce bootable media until the manual
checklist has been run and its results recorded there; every row in it is
still unchecked.

Two specific claims in this README are unverified and worth naming directly,
because both are load-bearing and neither can be reached by the automated
suite:

- **The cross-version claim.** The reason this tool reads Apple's catalog
  directly instead of wrapping `mist-cli` is so an Apple silicon Mac can
  write media for an old Intel target. Apple's own documentation says you
  generally must download from a Mac compatible with the macOS you're
  downloading. Whether this tool's bypass of that actually produces working
  media has never been tested, and the automated suite is faked end to end
  at exactly the download/assembly/write boundary where this would show up
  — it structurally cannot reach this question. See manual-verification row
  14.
- **No check of free space on the machine running the command.** The target
  drive's capacity is checked; the host machine's is not, and the download
  plus assembly needs roughly 30 GB there. If it runs out, that failure
  lands *after* you've already typed your drive's name to confirm the erase,
  at the end of a long download. See manual-verification row 16 and
  `docs/superpowers/plans/carry-forward.md`.

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

`create` will, in this order:

1. ask which Mac will boot the finished installer (skipped under `--brief`),
2. look up available versions and resolve `--version` to one of them,
3. show the Before-stage guidance (skipped under `--brief`),
4. print "Plug the drive in now, then press Return." and wait for Return —
   skipped when stdin is not a terminal (piped input, CI); the drive list in
   the next step is taken only *after* this wait, so a drive plugged in
   right at this prompt is still seen,
5. list mounted external volumes and apply the safety checks,
6. ask you to type the target volume's exact name to confirm, then
7. show the During-stage guidance (skipped under `--brief`),
8. download `InstallAssistant.pkg` for the requested version (resuming an
   interrupted download, retrying a dropped connection with backoff, and
   retrying once more from scratch on a digest mismatch),
9. verify it against Apple's published digest,
10. run `installer` to assemble `Install macOS X.app` (admin password
    required), then
11. run `createinstallmedia --volume <mount point> --nointeraction` as root,
    then
12. show the After-stage guidance and save it to a file on the Desktop
    (skipped under `--brief`).

**Confirmation happens at step 6, before anything is downloaded or
prepared.** Once you type the volume's name, the erase at step 11 is already
consented to and will run unattended at the end of a potentially 30+ minute
download and assembly, with no further prompt. Do not assume that because
the download is still running nothing has been committed yet, and do not
swap or unplug drives during that window — the target was already chosen and
confirmed.

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
enabled, and reports three numbers:

- **`MacOSInstallerKit` (the library) — gated, must stay at or above 93%.**
  This is the figure that fails the build.
- `macos-installer` (the executable) — informational only, not gated. This
  target is deliberately thin argument-parsing and wiring, excluded from
  coverage by design, so a low number here does not indicate rot.
- Combined library + executable — informational only, not gated. Quoting
  this number on its own, without naming it as the combined figure, makes a
  healthy library look worse than it is; quoting the library number alone,
  without naming it, overstates how much of the executable is exercised.
