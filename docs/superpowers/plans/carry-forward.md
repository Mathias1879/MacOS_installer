# Carry-Forward Notes

Findings and decisions from executing Plan 1 (version discovery) that later
plans must act on. Recorded here because the execution workspace is scratch and
gets deleted; these are the parts worth keeping.

## Do first in Plan 2

**`FakeCommandRunner` returns success for unstubbed commands.** An unstubbed
command currently yields `CommandResult(exitCode: 0, standardOutput: "", …)`.
Plan 2 introduces destructive commands, and a test that forgets to stub one
would see a passing no-op. Change the default to a non-zero result. This was
deliberately not done in Plan 1 — churning a green branch at the end of a
finished plan bought nothing.

**`VolumeGuard` must treat a size of 0 as "unknown, refuse", never "fits".**
Plan 1 made a zero size unreachable from all three sources via a single choke
point in `ReleaseCatalog`, but the guard itself should not assume that holds
forever.

**Filter `Deferred: YES` from `softwareupdate` output.** The field is parsed and
discarded today. Listing an unservable release is harmless; attempting to
download one is not. This is a Plan 2 blocker.

**Add the `sudo` refusal check.** The spec's Privilege Model says the tool
refuses to run under `sudo`. It is unimplemented. It must land *with* the
catalog cache, or the cache it protects gets written root-owned.

## Deferred design changes

**Per-product drop reporting.** When a `.dist` fetch fails, `SucatalogSource`
drops the product silently, so a partial CDN outage removes versions from the
list with no indication. `SucatalogSource` throws only when *every* product is
dropped, which distinguishes a total outage from an empty catalog. The fix is
`availableReleases()` returning releases plus failures, feeding
`ReleaseCatalog.Result.failures` unchanged — the channel already exists. Not
done in Plan 1 because it changes the `InstallerSource` contract across three
completed tasks.

**Redundant per-source sorting.** All three sources sort, and `ReleaseCatalog`
re-sorts the merged set. The per-source sorts are unobservable through the
protocol. Either document ordering in the `InstallerSource` contract or remove
all three.

**Case-sensitive filename matching** in `CatalogProduct.kind`. Mis-cased
filenames would drop the product — a visible absence, which is the safe
direction, so this is low priority.

## Unverified assumptions

**`LocalInstallerSource` reads `CFBundleDisplayName`, `DTPlatformVersion` and
`DTSDKBuild`** from an installer bundle's `Info.plist`. No real
`Install macOS *.app` existed on the development machine, so these key names are
covered only by synthetic fixtures. Verify against a genuine installer once
Plan 2's downloader can produce one, and correct if they differ.

**Legacy ESD assembly is unspecified.** Turning Mojave/Catalina chunked products
into a working `Install macOS X.app` is undocumented by Apple. Plan 4 opens with
a time-boxed spike against a real Catalina product before any code is written
against it.

## Not yet implemented from the spec

- The three-part user-facing error format (what happened / what it means / what
  to do next) and `~/Library/Logs/macos-installer/`. `ListCommand` currently
  interpolates raw errors to stderr.
- `docs/manual-verification.md`, the Tier 3 manual boot-test checklist. Correct
  to be absent now — there is nothing to boot-test until Plan 2 writes media —
  but it is a release blocker before any tag.
- The 24-hour catalog cache. Deferred from Plan 1 as an optimisation over a path
  that did not yet exist.

## Lessons for writing Plans 2–4

**Specify full-array ordering assertions.** Three separate tasks in Plan 1
shipped a sort that no test could fail, because the plan's tests asserted on
`.first` or on a single-element result. Write `#expect(x.map(\.field) == [...])`
into the plan text.

**Specify a negative test per declared error case.** Several error cases were
declared, reachable, and untested, with `#expect(throws: (any Error).self)` used
where a specific case was meant.

**Mandate mutation checks for correctness-critical guards.** Two tests in Plan 1
had names asserting more than their bodies proved, and both passed review by
reading. Only mutation caught them. One guard was untestable as designed and
needed an injected seam before it could be proven at all.

**Verify against real data early.** Every fixture in Plan 1 was cut from a
*modern* `.dist` file. Eleven tasks, 72 tests and four reviews of the parser all
missed that legacy files put a localization key in `<title>` — visible within one
second of rendering live catalog data.

## Do first in Plan 3 (carried from Plan 2, Task 13)

**`CommandRunner` needs a cancellable variant.** Long-running commands
(`curl`, `createinstallmedia`) currently run via `Task.detached`, which does
not inherit cancellation — Ctrl-C during a download is expected to leave the
`curl` process running as an orphan after the CLI exits. See
`docs/manual-verification.md` item 5. A cancellable variant is needed before
this can be fixed rather than just documented.

**Time Machine detection should use `APFSVolumeRole == "Backup"`, not name
matching, and should probably refuse rather than warn.** `VolumeGuard`
currently matches on `volumeName.localizedCaseInsensitiveContains("time
machine")`, which both over- and under-matches a real Time Machine volume.

**Mounted disk images are not refused.** `VolumeGuard` has no rule against a
mounted `.dmg`/`.sparsebundle` volume being offered as an erase target.

**`CatalogCache` is non-`Sendable`** while every other injected closure in
the codebase is `@Sendable`. Inconsistent concurrency contract.

**`ConfirmationPrompt` trims `.whitespaces` rather than
`.whitespacesAndNewlines`.** A pasted or terminal-mangled name with a
trailing newline could fail to match when it should, or in principle match
when it shouldn't.

**`selectRelease` takes the first version match and can hide a downloadable
sibling build behind a `softwareUpdate`-only one.** `CreateCommand.
selectRelease(from:)` returns `releases.first { $0.version.description ==
version }` — if two releases share a version string and the first one found
is `softwareUpdate`-only, a downloadable sibling with the same version is
never reached even though it would satisfy the request.

## Carried from Plan 2's final review

**The deadlock test has no time limit.** `CommandRunnerTests.doesNotDeadlockWhenChildFloodsStderr` spawns a real child that floods stderr. It passes in ~0.1s, but if the concurrent pipe drain in `RealCommandRunner` ever regresses, the test HANGS rather than failing. Add a Swift Testing `.timeLimit(.minutes(1))` trait whenever Plan 3 touches that file, so a regression fails cleanly.

**The residual path-vs-UUID window is irreducible and currently undocumented in code.**
`createinstallmedia --volume <mountPoint>` addresses a PATH, while every guard binds a UUID. Between `InstallMediaWriter` reading `volume.mountPoint` and `createinstallmedia` resolving that path, an unmount-plus-remount of a same-named volume at the same path would erase the wrong drive. It is one exec wide and cannot be closed without an Apple API that takes a volume UUID. It is real on any machine with two same-named volumes — this development machine has two called "Untitled". State it in a comment on `InstallMediaWriter.write` and in the README's safety section.

**Spec items still unimplemented after Plan 2:**
- Network retry with backoff. `Downloader.download` makes exactly one attempt; the spec asks for retry with backoff.
- Re-download once on digest mismatch. The code deletes the bad package and fails, deferring the retry to the user's next invocation; the spec asks for one automatic retry.
- `~/Library/Logs/macos-installer/`. Absent. For `writeFailedDriveStateUnknown` this is the one artifact worth keeping — the argv, exit status and stderr behind a possibly-ruined drive currently exist only in terminal scrollback. Highest-value item for Plan 3.

**Two error formatters with one responsibility.** `MediaWriteErrorFormatter` hand-writes "Nothing was written." into five of six cases while `PreparationErrorFormatter` appends a shared constant. Same guarantee, two mechanisms. Plan 3's three-part error format (what happened / what it means / what to do next) is the right moment to introduce one structured user-facing error type and port all six producers of user text to it: `VolumeGuard.RefusalReason.userMessage`, `InstallerPreparationError.userMessage`, both error formatters, and both table formatters.

**`InstallerPreparer` is misfiled.** It lives in `Assembly/` but is an orchestrator, not an `AssemblyStrategy`. Move it beside `Download/` or into its own `Pipeline/` directory.

**`AssemblyStrategy` is not actually used as a strategy.** `InstallerPreparer.prepare` switches on `release.payload` itself and throws for legacy, while holding one injected assembler. Plan 4 cannot simply drop in a `LegacyESDAssembler`: it must convert that switch into strategy selection, and `downloadAndAssemble` hardcodes a single-file `InstallAssistant-<build>.pkg` download that the chunked legacy layout will not fit.

**`"%.1f GB"` is duplicated** in `VolumeGuard` and `VolumeTableFormatter`.

**Time Machine detection is near-dead code.** Modern Time Machine volumes are rarely *named* "time machine", so the name-matching rule almost certainly never fires in practice. Do not count that warning as a shipped control until it keys on `APFSVolumeRole == "Backup"`.

## Carried from Plan 3, Task 4 (structured user-facing errors)

**`RefusalReason.userMessage` and `.explanation` are hand-copied prose that can drift.**
`VolumeGuard` now carries both a one-line table-cell string and a three-part explanation for each
refusal. Verified consistent today, and nothing couples them — `refusalReasonsHaveMessages` and
`refusalReasonsOfferNextSteps` each test their own property in isolation. Deliberately NOT coupled:
making a table cell and a three-part report share a source risks wording that suits neither. Revisit
only if they actually diverge.

**`DigestError.mismatch` and `DownloadError.sizeMismatch` assert the bad file "has been deleted"
while the deletion is best-effort `try?`** (`InstallerPreparer.swift:135,152`). Wording inherited
verbatim from the deleted `PreparationErrorFormatter`, not introduced by Plan 3. The honest fix
threads the deletion outcome into the case signature, churning the enum and its tests for a low-harm
case: if deletion fails, the next run simply fails again with the same clear message. Fix if the
enum is being reshaped anyway.

**`DiskEnumeratorError.listFailed` reaches `explain()`'s generic fallback.** Deliberate — `diskutil
list` failing outright IS unexpected, so "a gap in the tool" is honest for it. Listed so a future
reviewer does not read it as an oversight alongside the three refusal types that WERE conformed.

**`MediaWriteError.explanation` (~80 lines) and `RefusalReason.explanation` (~67) exceed the 50-line
function guideline.** Accepted exception: one switch per type with verbose per-case literals.
Splitting would hurt readability. Recorded so the final review does not re-raise it.

**Two error-message surfaces now exist per type and only one is exhaustiveness-guarded by default.**
The `exhaustivelyCheck*` helper pattern (an exhaustive `switch` with no `default`, called from the
test so the compiler checks it) is the project's answer to hand-maintained sample arrays silently
shipping gaps. It was proven necessary empirically: a new enum case with a dishonest explanation
passed a green suite before the helpers existed. ANY new test that samples enum cases by hand must
carry one.

## Carried from Plan 3, Tasks 5-6 (walkthrough content)

**Warning about sleep is the weaker half of the fix — the tool could prevent it.** The guidance now
tells the user to keep the drive plugged in and the Mac awake for the whole 30-60 minute unattended
window, because the erase happens at the END of it. Wrapping the long operation in `caffeinate`
would remove the failure mode instead of describing it. New behaviour and a new process invocation,
so it was out of scope for a wording fix.

**`TargetMacPicker`'s help is unbounded.** Asking "?" does not consume an attempt, by design, so a
non-interactive caller piping "?" endlessly never terminates (it does exit on EOF). Unreachable
interactively — a human typing "?" forever is making a choice. A separate generous help cap would
close it if it ever matters.

**The test target now depends on the `macos-installer` executable target** (`Package.swift`), so
`TargetMacPicker`'s retry/help loop can be tested via `@testable import macos_installer`. Internal
only. The alternative — moving the picker into the library — would put bare `print(...)` calls inside
`MacOSInstallerKit`, because the injected closure is NAMED `print` and shadows the global, which
would make the project's no-print grep guard unreliable. Keep the picker in the executable.

**A plan's sample code carries the plan author's factual errors with the authority of a spec.**
Task 5 spent THREE fix rounds on facts that were wrong in the plan, not in the implementation: an
assertion that all three boot methods differ (two Intel generations share one), a year-based T2
heuristic (no model year predicts T2 status), and "Controller" written as the only System Information
label (Apple's own article says "either Controller or iBridge, depending on the version of macOS").
Task 6 added two more: a "2018 and later" T2 claim, and an assertion that the target Mac needs
internet to install (Apple's article says nothing of the kind and the whole point is an offline
installer). For Plan 4: fact-check the plan's own user-facing strings against primary sources BEFORE
dispatch, and check them against earlier tasks' findings too — external verification does not catch
internal contradiction.
