# omawin — instructions for agents

Omarchy bar widget (`chaves.omawin`) for Omarchy's Windows VM. QML (`Panel.qml`,
`Service.qml`), a pure state machine (`lib/State.js`), bash helpers (`helpers/`),
the polkit rule and its `setup`. The README is the user-facing page;
read `docs/under-the-hood.md` before changing behaviour.

## `main` is the release channel

`omarchy plugin update` fetches the tip of `main` and fast-forwards to it; it
ignores tags and GitHub releases. **Anything pushed to `main` ships to every user
on their next update.** So:

- One branch per release (`fixes-X.Y.Z`), cut from `main`; never commit to `main`
  directly. Each fix is its own commit on it.
- Test each fix as it lands, then the whole branch together. `main` only
  fast-forwards to a branch tip that was tested as a whole.
- Routine branch commits, pushes and PRs are part of requested implementation.
  Merge or release when the owner has authorized that scope and relevant checks
  pass. Upstream maintainer approval applies to upstream publication, not work
  on Brandon's personal fork. UI changes need isolated desktop validation;
  physical acceptance is required only for behavior that isolation cannot prove.

## Every change gets a changelog line

`CHANGELOG.md` is the record users read: it is in the diff `omarchy plugin update`
shows them, and each GitHub release body is copied from it.

- User-visible changes add a line under `## Unreleased` in the same change.
- Write what the user notices, not what the code does: "Copy password no longer
  leaves the password in clipboard history", not "pass --sensitive to wl-copy".
- Group under `### Fixed`, `### Changed`, `### Added`, `### Removed` as needed.
- Pure refactors, tests, comments and documentation do not need a changelog entry.

## Releasing

1. Rename `## Unreleased` to `## X.Y.Z — YYYY-MM-DD` and start a fresh
   `## Unreleased` above it.
2. Bump the version in `manifest.json` **and** `pluginVersion` in `Panel.qml`.
3. Merge to `main`, tag `vX.Y.Z`, and create the GitHub release with that
   version's changelog section as its body.

## Working here

- Tests: `node --test tests/` — all unprivileged, against fixtures. Add a test for
  every fix the fixtures can reach.
- Shell is shellcheck-clean: `tests/shellcheck.sh` (also run by `node --test`)
  checks every tracked script with the repo's `.shellcheckrc`. Fix real findings;
  otherwise a per-line `# shellcheck disable=SCxxxx # reason`. Never change
  behaviour to please the linter.
- Visual and behaviour checks run in an omabox (load the `omabox` skill).
  Check the real bar only when the user requests physical acceptance. The debug IPC (`mock`, `fail`, `face`) reaches every card face
  without touching the VM; see the IPC table in `docs/developing.md`.
- Reuse the existing VM for authorized integration testing and preserve its data.
  Use fixture IPC when it proves the change. Removing or replacing the real VM
  requires explicit authorization. Keep its RAM at 8G or less.
- Fix one issue per commit, in the agreed order, so each can be tested alone.
