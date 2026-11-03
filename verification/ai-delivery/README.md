# AI delivery verification

Run on macOS with Xcode's Swift 6 toolchain and Python 3:

```sh
python3 verification/ai-delivery/run.py
```

Use `--results /path/to/results.json` to save the compiler output, check results, and source hashes. The runner builds in a temporary directory and removes it after execution. It does not contact an AI provider or open the app's archive.

The package links the production files in `packages/x-activities/Sources/Kapp` through relative symlinks. It does not copy or rewrite those files for testing. The three executables run concurrently, and each executable runs its cases in a Swift task group:

- `StoreProof` runs 38 cases against the actual `ActivityStore`, models, response parser, and renderer. Task-local database, media, importer, and AI substitutes control suspension and failure points. Cases cover completion beyond 120 polls, cancellation ownership, pending start, stale completions, output-mode snapshots, invalid responses, file and chat failures, export retention, and deletion ordering. The public app rejects deletion during an active import, which this fixture preserves.
- `ReportMediaProof` runs 10 cases against the actual parser, renderer, and `MediaStore`. It checks escaped content, restrictive CSP, source anchors, size limits, private file permissions, reopen behavior, retention, accounting, rollback, and symlink rejection. Each filesystem case uses a separate UUID directory.
- `DatabaseProof` runs 6 cases against the actual SQLite database and models. Its `databaseURL:` initializer points to a separate UUID fixture for each case. It checks message and thread retention, saved report links, reopen, explicit deletion, and failed writes. It removes every database fixture before returning.

These are source-level regression checks. They do not verify native window behavior, the live host/provider transport, or package installation. Run the full Kapp build and catalogue validation separately. The existing `verification/pending-media-cleanup` proof covers the public schema-v4 screenshot cleanup behavior.
