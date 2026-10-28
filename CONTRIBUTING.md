# Contributing to EasyPass

Thanks for considering a contribution. This document covers how to get a change
merged; the deep conventions live in [`AGENTS.md`](AGENTS.md).

> **Read [`AGENTS.md`](AGENTS.md) before your first change.** It is the authoritative
> guide to this codebase — architecture, layering rules, and a long list of pitfalls
> that each cost real debugging time. This file does not repeat it.

## Getting set up

Requirements:

- **Flutter** with Dart SDK `^3.12.2` (see `pubspec.yaml`).
- **Node.js** for the browser-extension self-checks.
- No extra tooling for the checks below (they deliberately avoid MSBuild), but Inno
  Setup 7 if you want to build the installer yourself.

```bash
flutter pub get
dart run build_runner build          # only needed after editing lib/data/database/tables.drift
flutter gen-l10n                     # only needed after editing lib/l10n/*.arb
```

## The verification gates

Run these before opening a pull request. All of them are read-only and safe:

```bash
flutter analyze --no-pub
flutter test --no-pub

# browser extension (jsdom comes from `npm ci` via the committed lockfile)
npm ci && npm run test:extension   # = check_extension + the three jsdom smokes
# or individually:
node browser_extension/tools/check_extension.mjs
node browser_extension/tools/smoke_content.mjs
node browser_extension/tools/smoke_popup.mjs
node browser_extension/tools/smoke_popup_extra.mjs

# Windows runner sources (no MSBuild, no artifacts)
cmd /c windows\runner\check_syntax.bat
```

CI runs the same set on every push, so a green local run means a green PR.

**Reading the test count.** A Windows run currently reports **730 passing** (63 test files).
A few platform-specific tests have `skip:` guards on unsupported hosts (DPAPI / system
clipboard), so a run can report fewer cases than are declared — that is a reduced case
count, not failures. Do not "fix" the numbers by forcing platform-specific tests to run
everywhere.

If something behaves strangely only when launched from `build\` — no tray icon,
settings that do not stick — run `cmd /c windows\runner\check_integrity.bat` before
suspecting the code. A Low mandatory integrity label on the workspace silently
demotes the process; the script detects it and `/fix` repairs it. Details in
`AGENTS.md`.

**Building on Windows: stop a running EasyPass first.** `flutter build windows` fails
with `MSB3073` when an instance launched from `build\windows\x64\runner\Release` is
still alive, because a POST_BUILD step cannot overwrite the MSVC runtime DLLs it has
mapped. One-line fix in `AGENTS.md`.

## Two rules that are easy to get wrong

**1. Formatting — do not run `dart format`.** This repository predates the Dart 3.13
formatter. Running it rewrites hundreds of untouched lines and buries the real change
in the diff. `flutter analyze` is the gate; match the surrounding style by hand.

**2. `windows/runner/**` must stay pure ASCII.** `cl.exe` is invoked without
`/utf-8`, so it decodes those sources using the system ANSI code page. A Chinese
comment or a full-width punctuation character trips warning C4819, which `/WX` turns
into a build failure (and can shift the reported line numbers enough to look like a
syntax error). Comments elsewhere in the tree are mixed Chinese/English and that is
fine.

## Working on the schema

Anything that touches `lib/data/database/tables.drift` needs three things, not one:

1. `dart run build_runner build` to regenerate `database.g.dart`.
2. A bump of `schemaVersion` **and** a real `onUpgrade` branch in
   `lib/data/database/database.dart` — existing installs must be able to open their
   old database. A missing branch surfaces as `no such column` / `no such table` on
   upgrade only, which unit tests on a fresh database will not catch.
3. An extension of `test/migration_test.dart`, which hand-builds an old schema and
   asserts the upgrade. Add a fixture for the version you are migrating from.

Bump `drift`, `drift_dev` and `build_runner` together if codegen fails with
`Missing implementation of visitDotShorthandPropertyAccess` — that is an analyzer/SDK
mismatch, and `--delete-conflicting-outputs` may already have removed the old
generated file, leaving the tree uncompilable until you fix the versions.

## Commit and branch conventions

- Branch from `master`; commits go to `master` (no long-lived branches).
- Commit messages are **Chinese**, in `type: description` form — for example
  `add:添加了浏览器扩展的图标`, `fix:安装包缺少MSVC运行时导致打包失败`.
- Keep a commit to one logical change. Explain *why* in the body when the reason is
  not obvious from the diff; the tests say what, not why.

## Version numbers

Semantic versioning, synced in **four** places or
`check_extension.mjs` will fail the build:

| File | Field |
| --- | --- |
| `pubspec.yaml` | `version:` |
| `lib/features/settings/screens/settings_screen.dart` | the version shown on the Settings screen |
| `browser_extension/manifest.json` | `version` |
| `installer/easypass_setup.iss` | `MyAppVersion` and `VersionInfoVersion` |

`y` for features, `z` for fixes and polish, `x` for architecture or security-model
changes (a new platform counts as a feature). Update `README.md`, `README_zh.md` and
`CHANGELOG.md` in the same change.

## Translations

Every user-visible string lives in `lib/l10n/app_en.arb` (source) and
`app_zh.arb`. Both must stay in sync — the same key count, with placeholders
declared. Run `flutter gen-l10n` after editing. If you add a string and only
translate one language, say so in the pull request rather than leaving a silent
English string in the Chinese UI.

## What gets merged

- **Tests.** New behaviour needs a test. Bugs need a test that failed before your fix
  — say so in the pull request, it is the most useful thing a reviewer can see.
- **No new dependencies without justification.** The extension packaging and release
  scripts are deliberately dependency-free. For Dart, explain what a package buys over
  the standard library.
- **Failures are reported, never swallowed.** The codebase has a house style here:
  a failed write shows an error or a SnackBar; it never silently falls back to a
  default that looks like success. If your change has a failure path, make it visible.
- **Destructive actions state their blast radius.** A confirm dialog that reads the
  same for "this folder is empty" and "this folder has 40 entries" is a bug.

## Security

Do not report vulnerabilities in a public issue or pull request. See
[`SECURITY.md`](SECURITY.md) for the private reporting channel and for the security
model — including which properties are known limitations rather than bugs.

## Licence

Contributions are accepted under GPL-3.0 (see [`LICENSE`](LICENSE)). By opening a
pull request you confirm you have the right to submit the work under that licence.

