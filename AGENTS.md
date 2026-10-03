# Repository instructions

These instructions apply to the entire repository.

## Build output

- Before every app build, remove the previous `build/Porter.app` and
  `build/DerivedData`. Clean any other stale Porter build output found in the
  workspace as part of that build.
- Use `build/DerivedData` for Xcode intermediates and `build/Porter.app` for the
  single current app bundle. Keep build output inside this workspace instead of
  creating additional build trees in temporary directories.
- Regenerate `Porter.xcodeproj` from `project.yml` before building. The project
  compiles PorterKit as a local static library target.
- After a successful build, copy the complete app and embedded Finder extension
  to `build/Porter.app`, verify the bundle and its signature, and remove
  `build/DerivedData` so there is one app copy.
- Replace `build/build.log` and any build metadata with the current build's
  records. If a build fails, leave the canonical app path empty and report the
  failure rather than presenting an older app as current.
- Swift package tests and CLI builds use the consistent `Kit/.build` directory.
  Reuse that directory or clean it when needed; keep compiler caches under
  `build/` when a writable cache override is required.

## Validation

- Run tests within the workspace sandbox. Keep the outer sandbox enabled when
  compiler or SwiftPM subprocesses require their nested sandbox to be disabled.
- Use command-line build and bundle checks. Do not use the desktop UI for tests.
- Launch the app only when the user explicitly requests it.
