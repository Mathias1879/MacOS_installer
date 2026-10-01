# Manual Verification Checklist

**This checklist must be completed before any release tag.** The automated
suite is 183 tests and zero USB sticks: nothing in CI has ever written real
media or booted a Mac from it. Every claim the README makes about what this
tool does on real hardware is only as true as the rows below.

**Any row left unchecked, or checked "fail," must be reflected honestly in the
README.** Do not mark a capability as working in the README until its row
here is checked and passing. If a row cannot be run yet, the README must say
so (e.g. "not yet verified — see `docs/manual-verification.md`"), not imply
success by omission.

Each row has space to record what actually happened, not just pass/fail —
several of these are "describe the behavior" checks, because the point is
discovering what Apple's tools actually do, not confirming a guess.

---

## Preconditions

- [ ] A spare USB drive, **32 GB or larger**, whose current contents are
      expendable, is connected.
- [ ] The drive's device identifier has been noted before starting
      (`diskutil list`), e.g. `/dev/diskN`.
- [ ] Device identifier used for this run: `______________________`

> **DO NOT use `disk5s1` or `disk6s2` on the development machine.** Both are
> named "Untitled" and both hold live project work (website repositories and
> other active projects belonging to the user). They exist for the
> non-destructive section below — to confirm the ambiguous-name refusal fires
> — precisely because they are real volumes with a real name collision.
> Neither may ever reach a confirmed erase. If `create` gets as far as the
> typed-name confirmation prompt for either of these, abort by typing
> anything other than the exact displayed name.

---

## Section A — Non-destructive (safe to run on any machine, including this one)

Everything here stops before any write. Confirm the guard fires correctly
and nothing changes.

- [ ] **Internal volume refused.** Run `macos-installer create --version <v>`
      with no `--volume`. Confirm the startup disk's internal volumes do not
      appear as selectable, and that `Macintosh HD` (or the current machine's
      internal volume name) is listed as refused if shown at all.
  - Observed: ________________________________________________

- [ ] **Boot container and its snapshot both refused.** Confirm both the
      visible boot volume and its sealed system snapshot are refused — not
      just one of the two.
  - Observed: ________________________________________________

- [ ] **Whole disks refused**, not offered as targets (only volumes).
  - Observed: ________________________________________________

- [ ] **Ambiguous `--volume` refusal fires on real hardware.** On the
      development machine, run
      `macos-installer create --version <v> --volume Untitled`. There are two
      external volumes named "Untitled" (`disk5s1`, `disk6s2`). Confirm the
      tool refuses and names both candidates by device identifier, rather
      than silently picking one. **Do not proceed past this refusal** — do
      not disambiguate to either real drive and do not confirm an erase.
  - Observed: ________________________________________________

- [ ] **Deliberately wrong typed name aborts, nothing changed.** On the spare
      drive from Preconditions, get to the typed-confirmation prompt and type
      a name that does not match. Confirm the tool reports the mismatch and
      exits without touching the drive (check with `diskutil list` /
      `diskutil info` afterward — same volume name, same UUID, same content).
  - Observed: ________________________________________________

---

## Section B — Destructive (spare drive only)

Everything below this line can erase the spare drive. Re-confirm the device
identifier noted in Preconditions before each step.

### 1. Boot test — Apple silicon Mac

- [ ] Shut the target Mac down completely.
- [ ] Connect the drive. Hold the power button until "Loading startup
      options" appears, then select the installer volume.
- [ ] Confirm the macOS installer UI loads (language picker / "Install
      macOS" screen).
- Host Mac used to write media: ________________________________
- Target Apple silicon Mac (model): ____________________________
- Result (pass/fail): ___________  Notes: ______________________

### 2. Boot test — pre-T2 Intel Mac (2012–2017)

This is the row that makes "supports older Macs" a true claim. Without it,
legacy-hardware support is a reasoned guess, not a verified fact.

- [ ] Shut the target Mac down completely.
- [ ] Connect the drive. Hold Option (⌥) immediately at power-on, select the
      installer volume from the Startup Manager.
- [ ] Confirm the macOS installer UI loads.
- [ ] If the target Mac has a T2 chip, confirm Startup Security Utility is
      set to allow booting from external/removable media *before* this test
      — otherwise the drive will not appear in Startup Manager even if it
      was written correctly, and that is not a tool failure.
- Target Intel Mac (model, year): ______________________________
- T2 chip present? Y / N — Startup Security Utility setting: ___________
- Result (pass/fail): ___________  Notes: ______________________

### 3. `--nointeraction` acceptance by `createinstallmedia`

`InstallMediaWriter` passes `--volume <mountpoint> --nointeraction`. This
flag is specified from Apple's documentation; nothing on the development
machine has run the real binary. Record what actually happens:

- [ ] Does `createinstallmedia` accept `--nointeraction` without error?
- [ ] Does it actually suppress the interactive "Erase disk... (y/N)?"
      prompt, or does the process hang waiting for input with no visible
      output (a silent hang)?
- [ ] If rejected or hung: capture the exact stderr/stdout text and file a
      fix before relying on this path unattended.
- Observed: ________________________________________________

### 4. Sibling partitions on the same whole disk

`createinstallmedia --volume <volume>` targets one volume, not the whole
disk. Reasoned about, never observed.

- [ ] Before writing, partition the spare drive into two volumes (e.g.
      `Spare1` and `Spare2`) and put a marker file on each.
- [ ] Run `create` targeting only `Spare1`.
- [ ] After it completes, confirm `Spare2` still exists as a separate
      partition on the same disk with its marker file intact — i.e. the tool
      erased the targeted volume, not the whole disk.
- Observed: ________________________________________________

### 5. Ctrl-C during download

`Task.detached` inside `ResumableTransfer` does not inherit cancellation, so
the download's `curl` is expected to keep running as an orphaned process
after the CLI exits.

- [ ] Start `create` and let the download begin.
- [ ] Press Ctrl-C partway through.
- [ ] Check `ps aux | grep curl` — is the curl process still running after
      the CLI has exited?
- [ ] If it is, let it finish (or kill it manually) and re-run `create` for
      the same version. Does the tool reuse/resume the partial file, or
      detect a mismatch and re-download from scratch?
- Observed (process survives? Y/N): ____________________________
- Observed (partial file reusable on next run? Y/N): ___________

### 6. TCC prompt — "Terminal would like to access files on a removable volume"

Apple documents this prompt appearing mid-run.

- [ ] During a real `create` run against the spare drive, note whether this
      (or an equivalent TCC) dialog appears.
- [ ] If it appears, note **at which step** (download, assembly, or the
      `createinstallmedia` write) so a future guided-walkthrough phase can
      pre-announce it accurately.
- Appeared? Y/N — At which step: ________________________________

### 7. `LocalInstallerSource` Info.plist keys against a real installer app

`CFBundleDisplayName`, `DTPlatformVersion`, and `DTSDKBuild` are read from
`Install macOS *.app/Contents/Info.plist`. Only synthetic fixtures have ever
exercised this — no genuine installer app existed on the development
machine.

- [ ] After a `create` run downloads and assembles a real
      `Install macOS *.app`, run `macos-installer list` (or
      `list --offline`) again.
- [ ] Confirm the newly-installed app is listed as "on disk" with the
      correct name, version, and build.
- [ ] If it is missing or shows wrong/blank values, the key names
      (`CFBundleDisplayName`, `DTPlatformVersion`, `DTSDKBuild`) are wrong
      against real installer apps and need correcting.
- Observed: ________________________________________________

### 8. Digest mismatch recovery, end to end

`InstallerPreparer` deletes a rejected package on digest mismatch so a later
run re-downloads it. Never observed end to end.

- [ ] Force a digest mismatch (e.g. truncate or corrupt the cached
      `InstallAssistant-<build>.pkg` in the cache directory after a partial
      or full download, or interrupt and corrupt mid-transfer).
- [ ] Run `create` again for the same version.
- [ ] Confirm the tool reports the digest error, deletes the bad file, and
      that the *next* run re-downloads successfully and assembles correctly
      — rather than repeating the same digest failure forever.
- Observed: ________________________________________________

---

## Results Table

| macOS version written | Host Mac | Target Mac | Pass/Fail | Date |
|---|---|---|---|---|
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
