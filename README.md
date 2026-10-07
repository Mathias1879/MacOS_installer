# MacOS_installer

A macOS command-line tool that finds a requested version of macOS, downloads
it from Apple, and writes a bootable offline installer to a USB drive or
other external volume.

This repository currently implements **version discovery**: finding every
macOS version available to write, from three sources —

- an `Install macOS *.app` already present on disk,
- `softwareupdate --list-full-installers` (filtered to what the host model
  supports), and
- Apple's public software update catalog (unfiltered, so it can reach
  versions the host itself could never run).

Media creation (download, assembly, and writing to a drive) is not yet built;
see `docs/superpowers/plans/2026-09-26-version-discovery.md` for the roadmap.

## Requirements

- macOS 13 (Ventura) or later
- Swift 6 toolchain (ships with Xcode 16+, or via Command Line Tools)

## Building and running

```bash
swift build
swift run macos-installer list            # every version, including Apple's full catalog
swift run macos-installer list --offline  # skip the network catalog; softwareupdate + local only
```

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
