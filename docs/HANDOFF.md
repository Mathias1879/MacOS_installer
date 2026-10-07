# Handoff — where this project stands

Last updated: 2026-10-07, after Plan 3 (guided walkthrough) was completed and PR #3 opened.

Read this first if you are picking the project up after a break, or on a different machine.

---

## The one-sentence state

Three plans are built and reviewed, **none are merged**, and **nothing has ever written a real USB
stick or booted one** — so the tool is implemented and unproven, which is exactly how the README
describes it.

## Branches and PRs

Nothing is merged. The branches stack, and each PR targets the one below it:

| PR | Branch | Targets | What it is |
|----|--------|---------|------------|
| [#1](https://github.com/Mathias1879/MacOS_installer/pull/1) | `version-discovery` | `main` | Plan 1 — `list` every obtainable macOS release |
| [#2](https://github.com/Mathias1879/MacOS_installer/pull/2) | `media-creation` | `version-discovery` | Plan 2 — download, guard, write bootable media |
| [#3](https://github.com/Mathias1879/MacOS_installer/pull/3) | `guided-walkthrough` | `media-creation` | Plan 3 — the first-time-user walkthrough |

Review and merge **bottom-up**: #1, then #2, then #3. Merging out of order will produce confusing
diffs, because each branch contains everything below it.

`guided-walkthrough` is the newest and most complete branch — 316 tests, 95.97% library coverage.
If you want to run the tool, check that branch out.

## Before you run anything

**Use `./scripts/test.sh`, never bare `swift test`.** Command Line Tools ship the Swift Testing
macro plugin in a subdirectory SwiftPM does not search, so bare `swift test` fails with
`plugin for module 'TestingMacros' not found`. The script passes `-Xswiftc -plugin-path`. Same for
`swift build --build-tests`, which fails the same way — it is not a usable probe in this repo.

**`./scripts/ci.sh`** gates `MacOSInstallerKit` coverage at 93% and reports the executable and
combined figures as informational only. The executable is thin wiring by design and sits near 10%;
do not read that as rot, and do not quote the combined figure without saying which number you mean.

**Two volumes on the development Mac are both named "Untitled"** and hold live project work
(website repositories). This is not hypothetical — it broke volume enumeration and made the
typed-name confirmation meaningless during Plan 2, and it is why ambiguous `--volume` refuses. Never
pass `--volume` while testing, and never run `createinstallmedia`, `installer`, `sudo`, or `diskutil`
in write mode against this machine.

**The development Mac was at 1.4 GiB free of 228 GiB** as of 2026-10-05. `create` needs roughly
30 GB of host space (~15 GB for the package, as much again once `installer` expands it), so it
cannot currently succeed there. See the free-space gap in `carry-forward.md`.

## What to do next, in priority order

### 1. Run the manual verification — this gates every claim

`docs/manual-verification.md`, **16 rows, all unchecked.** Until it is run, "writes bootable media"
is implemented, not proven. The highest-value rows:

- **Rows 1 and 2** — boot tests on Apple silicon and on a pre-T2 Intel Mac (2012–2017). The Intel one
  is what makes any claim about older Macs true.
- **Row 14** — the cross-version claim. This is the stated reason the project is an original
  implementation rather than a `mist-cli` wrapper: reading Apple's catalog directly so a modern Mac
  can write media for an old Intel target. Apple's own documentation says you generally must download
  from a Mac compatible with the macOS being downloaded. Whether the bypass works has never been
  tested, and the automated suite **structurally cannot reach it** — the download, assembly and write
  path is faked end to end. If this fails, the README's cross-version claim and the spec's
  "own implementation, not a wrapper" justification both need rewriting.
- **Row 3** — whether `createinstallmedia` actually accepts `--nointeraction`. Specified from Apple's
  docs and never run.

Needs a spare 32 GB+ drive whose contents are expendable, and a Mac with ~30 GB free.

### 2. Merge the stack

Review #1, #2, #3 in that order. They have each had a per-task review, fix rounds, and a
whole-branch review, but no human has read them.

### 3. Plan 4 — legacy ESD (Mojave and Catalina)

Not written yet. Mojave and Catalina are **listed but not writable**: they use a chunked ESD payload
whose assembly Apple does not document. **Plan 4 must open with a time-boxed spike** against a real
Catalina product before any code is written, because the reassembly format is unknown.

It also cannot just drop in a new assembler: `AssemblyStrategy` is not actually used as a strategy
today — `InstallerPreparer.prepare` switches on the payload itself and `downloadAndAssemble` hardcodes
a single-file `InstallAssistant-<build>.pkg` download that the chunked layout will not fit. That
conversion is part of Plan 4's work. See `carry-forward.md`.

### 4. The deferred items

`docs/superpowers/plans/carry-forward.md` carries every deferred item with its reasoning. The two
worth doing before any public release:

- **The volume table** prints ~21 refusal rows with no header, immediately after "Everything on that
  USB drive will be erased. There is no undo." It is the screen a first-time user is most likely to
  quit at, and the only place the writing quality elsewhere has not reached. It also shows capacity
  rather than free space, so a blank 32 GB stick and a 2 TB drive full of work look identical.
- **No host free-space check.** The failure lands *after* the user has typed their drive's name to
  confirm, at the end of a long download, for a condition knowable in the first second.

## Where the documents are

Read in this order to come up to speed:

1. **`README.md`** — what works, what does not, and the "Verified on" section, which is the honest
   summary of what is proven.
2. **`docs/superpowers/specs/2026-09-26-macos-installer-design.md`** — the binding design authority.
   Note two known staleness points: its Data Flow diagram still shows
   `target Mac picker → BEFORE guidance → version picker`, which is impossible (the Before stage
   embeds the installer name, which does not exist until a version is chosen) and was reversed in the
   code; and it still carries a claim that the target Mac must be online during installation, which
   research disproved and the code dropped. Fix both when Plan 4 touches the spec.
3. **`docs/manual-verification.md`** — the release gate.
4. **`docs/superpowers/plans/carry-forward.md`** — deferred items, unverified assumptions, and
   lessons for writing later plans.
5. The three plan documents under `docs/superpowers/plans/`, if you need task-level detail.

**Not committed:** the execution ledger at `.superpowers/sdd/2026-10-03-guided-walkthrough/progress.md`
(~1,600 lines) holds every ruling made while executing Plan 3, with reasoning and cost-if-wrong.
`.superpowers/` is gitignored because it is scratch, so **it does not travel to another machine**.
Everything from it that matters beyond Plan 3 has been distilled into this file and into
`carry-forward.md`. If you are on the original development Mac it is still there and worth skimming
for the detail behind any decision below.

## Hard-won facts worth not rediscovering

**No model year predicts T2 status.** The iMac Pro (late 2017) was Apple's first T2 Mac; the 2019 iMac
has none; yet 2019 *is* a T2 year for the Mac Pro, MacBook Pro 16-inch and MacBook Air. One year maps
to both answers depending on the family, so a year-based heuristic has no correct form. Three fix
rounds were spent removing one. Apple's article is titled "Mac computers **with** the Apple T2
Security Chip" and says to look under **either "Controller" or "iBridge"**, depending on the macOS
version — naming only one of those labels silently misroutes a real T2 Mac.

**`/` is a sealed snapshot.** `diskutil info -plist /` reports a volume whose `VolumeUUID` differs
from the real boot volume's. A guard comparing UUIDs would not recognise the startup disk and would
offer it for erasure. `BootVolumeResolver` keys on `APFSContainerReference`, which both share.

**`createinstallmedia` erases and reformats the drive itself**, as Mac OS Extended (Journaled), and
renames the volume after the installer. Do not tell users to format it first.

**Apple recommends a 32 GB drive**; 16 GB suffices for most earlier versions. That number is Apple's,
not invented.

**The password prompt arrives third, not first**, and usually twice on the download path — `sudo
installer` during assembly, then `sudo -v` before the write, because sudo's five-minute timestamp
expires while installing an 18 GB package.

## The two process lessons that cost the most

**A plan's sample code carries its author's factual errors with the authority of a spec.** Plan 3's
dominant source of defects was not implementation error — it was the plan text and the fix briefs:
five wrong facts about Apple hardware and macOS behaviour, one ordering contract that was impossible
to implement, and three cases of specifying a feature while omitting the invariant that mattered.
Fact-check a plan's own user-facing strings against primary sources *before* dispatch, and check them
against earlier tasks' findings too — external verification does not catch internal contradiction.

**Verify that a fix achieved its goal, not that the code changed.** The Before stage was reordered to
print before volume enumeration and the change was accepted after confirming the source order had
changed. Nothing waited in between, so a user who read "plug the drive in" and did exactly that still
could not be seen. The reorder bought source-order tidiness and nothing a user experiences. The
whole-branch review caught it; `BeforeStageOrdering`'s doc comment records it.

**Fourteen tests shipped during this project that could not fail for their stated purpose.** Three
recurring causes, all worth watching for:

1. asserting a **shape** — a prefix, a substring, a non-empty value, a mere ordering — where an exact
   value was available;
2. computing the expectation from **the code under test**, so both sides of the comparison move
   together;
3. a **fixture too weak** to exercise the property — a fake that threw before doing the thing the test
   was named for, or a sample value that coincided with the fallback it was meant to distinguish.

A corollary that caught us repeatedly: **a zero failure count and a broken build produce identical
output.** Confirm the build exits 0 before drawing any conclusion from a mutation. The same applies to
shell checks — `grep | sed` with `|| echo` attaches the fallback to `sed`, so the fallback never
fires, and `find -newermt` silently returned nothing on this machine while a file carried a matching
timestamp.
