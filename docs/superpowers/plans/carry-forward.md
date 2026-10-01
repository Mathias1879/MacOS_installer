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
