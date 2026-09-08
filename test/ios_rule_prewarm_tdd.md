# iOS Rule Prewarm TDD Record

## RED

- Added scheduler and integration tests before implementation.
- The initial RED command was blocked because Flutter was not installed/on
  `PATH`; no fabricated scheduler failure is claimed.
- Once Flutter and dependencies were available, the first import integration
  execution failed with `Expected: <profile id>, Actual: <null>`, exposing the
  need to keep the auto-dispose current-profile provider alive in the harness.

## GREEN

- `flutter test test/core/rule_preparation_scheduler_test.dart test/core/controller_test.dart test/providers/action_test.dart`
  passed all 77 tests.
- `flutter analyze` over the seven changed Dart/test files reported no issues.
- `git diff --check` passed.

The repository lockfile initially referenced `window_manager` commit
`7ddbd876`, whose declared `packages/window_manager` path is absent. Tests were
run after a local-only targeted dependency refresh; generated registrants and
`pubspec.lock` were restored and are not part of this change.
