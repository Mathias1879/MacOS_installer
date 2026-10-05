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

- [ ] **Time Machine warning fires against a genuinely Time-Machine-named
      volume.** Rename the spare drive from Preconditions to something
      containing "Time Machine" (e.g. `Time Machine Backups`) and run
      `create` targeting it. Confirm the `⚠ This looks like a Time Machine
      backup.` warning is printed above the confirmation prompt — then abort
      by typing a non-matching name. Do not proceed to a confirmed erase for
      this check; it only needs to reach and show the warning.
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

### 9. Size-mismatch recovery, end to end

`InstallerPreparer` now deletes a cached package on a size mismatch too, not
only on a digest mismatch (see the fix for the oversized/stale-cache wedge).
Never observed end to end.

- [ ] Force a size mismatch (e.g. truncate the cached
      `InstallAssistant-<build>.pkg`, or substitute a same-or-larger-but-wrong
      -length file at that path, so `Downloader` sees `alreadyHave >=
      expectedBytes`, skips the transfer, and the final size check fails).
- [ ] Run `create` again for the same version.
- [ ] Confirm the error message names the full path of the cached file, that
      the file is deleted, and that the *next* run re-downloads successfully
      — rather than failing identically forever.
- Observed: ________________________________________________

### 10. Download progress does not freeze (Finding 1 regression check)

Before the concurrent-pipe-drain fix, curl's stderr progress meter could fill
the ~64 KB pipe buffer in roughly 10 minutes and deadlock the whole download,
which looked like a frozen/stale percentage rather than a crash or error.

- [ ] Start `create` for a version requiring a real download and watch the
      `Downloading… NN%` line for its full duration.
- [ ] Confirm the percentage visibly advances throughout — in particular,
      past the ~10-minute mark — rather than freezing at a stale value while
      the process appears to still be running.
- [ ] If it freezes, do not assume this is fixed just because the automated
      `CommandRunnerTests` deadlock test passes — that test proves the
      mechanism is fixed in isolation, not that nothing else in this path can
      still freeze.
- Observed: ________________________________________________

### 11. sudo's `Password:` prompt, given both pipes are now captured

`RealCommandRunner` redirects both stdout and stderr to pipes it reads itself
(necessary for the Finding 1 fix). Confirm that redirection does not also
swallow the interactive password prompt `createinstallmedia`/`installer`
need from the user.

- [ ] During a real `create` run that reaches the assembly or write step,
      confirm the `Password:` prompt is visible in the terminal and that
      typing the password works normally.
- [ ] If the prompt is missing, garbled, or input does not reach it, this is
      a regression from pipe capture and blocks the destructive steps below
      until fixed.
- Observed: ________________________________________________

### 12. Output visibility during the `createinstallmedia` write

The 20–45 minute `createinstallmedia` write is the step most likely to look
hung even when it is working, especially now that its stdout/stderr are
captured rather than inherited.

- [ ] During a real write, note whether any output appears on the terminal
      while it runs, or whether the terminal shows nothing for the full
      duration.
- [ ] If nothing appears, confirm (e.g. via `ps aux` or by waiting it out)
      that the process is still progressing and not actually hung — and note
      this so a future UX pass can add a heartbeat if the silence is
      genuinely indistinguishable from a hang.
- Observed: ________________________________________________

### 13. `--yes` end to end

No row previously exercised `--yes` at all, even though it is the flag that
removes the primary safety control (the typed-name prompt) for the common
case.

- [ ] Run `create --yes` targeting the spare drive (a volume that is
      *selectable*, not warned). Confirm no typed-name prompt appears and the
      erase proceeds directly after the pre-erase warning text.
- [ ] Separately, rename the spare drive to contain "Time Machine" and run
      `create --yes` targeting it. Confirm the typed-name prompt **still
      appears** despite `--yes` — this is the Finding 3 fix: `--yes` must not
      remove the control a flagged volume requires. Abort with a
      non-matching name rather than completing this erase.
- Observed (plain volume, --yes skipped prompt? Y/N): ___________
- Observed (Time-Machine-named volume, --yes still prompted? Y/N): ______

---

## Results Table

| macOS version written | Host Mac | Target Mac | Pass/Fail | Date |
|---|---|---|---|---|
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |

### 14. Cross-version write — the project's central claim

This is the differentiator the tool exists for, and NOTHING in the automated suite can
reach it: the download, assembly and write path is faked end to end in tests.

Apple's own instructions for creating a bootable installer state: "In most cases, you
must download from a Mac that is compatible with the macOS you're downloading." This
tool deliberately bypasses that gate by fetching `InstallAssistant.pkg` straight from
Apple's CDN via the software update catalog, instead of asking `softwareupdate`, which
refuses incompatible versions. Whether the bypass actually produces working media has
never been tested.

Two things can fail independently, and both must be checked:

- [ ] **Does `installer -pkg InstallAssistant.pkg -target /` succeed on an INCOMPATIBLE
      host?** Run `create` on a modern Mac for a macOS release that host cannot itself
      run (e.g. Big Sur from a current Apple silicon Mac). The package may carry a
      volume check or distribution requirement that refuses outright.
      Result: ______________________
- [ ] **If it installs, does that installer app's `createinstallmedia` RUN on the newer
      host?** An older installer's binary may be refused or may fail against a newer
      system. Capture the exact error if it does.
      Result: ______________________
- [ ] **Does the resulting stick actually boot the OLDER target Mac?** This is the only
      result that settles the claim.
      Result: ______________________

If any of the three fails, the README's cross-version claim and the spec's "own
implementation, not a wrapper" justification both need rewriting — that reasoning rests
entirely on this working.

Host used: ______________________  macOS written: ______________________
Target Mac: ______________________  Date: ______________________

### 15. The volume name in the instructions matches the real drive

The exported instructions and the after-stage walkthrough both tell the user to look for a
volume named `Install <installer name>` at the boot picker. That string is DERIVED by this
tool, not read back from the drive, and has never been compared against what
`createinstallmedia` actually produces. If it differs by even a word, the user is hunting
for a name that is not on screen, which is indistinguishable to them from a failed write.

- [ ] After a successful write, run `diskutil list` and record the volume's ACTUAL name
      exactly as it appears.
      Actual name: ______________________
- [ ] Record what the exported instructions file says to look for.
      Instructions say: ______________________
- [ ] Confirm the two match character for character, including any parentheses or
      punctuation in the macOS version's title.
- [ ] Confirm the name shown in the Mac's own startup picker matches as well — it may
      differ from the `diskutil` name.
      Startup picker shows: ______________________

If they differ, the derivation in `GuidanceCatalog` needs replacing with the name read back
from the drive after the write completes.
