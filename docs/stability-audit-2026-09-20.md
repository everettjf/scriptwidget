# Stability maintenance patch — 2026-09-20

Baseline: `6b0f390` (27.0.4 / 27005). Version numbers are unchanged; the maintainer will submit the next release. No App Store upload or review submission is part of this patch.

## Repaired paths

- Live Activity creation waits for the current document to save and for a complete extension-visible package to be prepared. A failed build or rejected system request no longer reports success. Both activity surfaces show recovery guidance when a script cannot be read.
- Build publication stages and validates files before replacement, retains the previous package on preparation failure, rejects symlinks and unresolved iCloud placeholders, and coordinates publication with per-file cache writers. Reading a build file no longer writes it back to itself.
- Renaming or deleting a package ends its existing Live Activities. The iOS editor tracks the renamed package and selected file; rename notifications are scoped to the old package name.
- Package 2.0 main reads resolve the manifest entry, including nested entries and cached manifests after eviction. Malformed present manifests cannot be exported by silently rewriting them as legacy manifests. Network permission checks also recognize unavailable/cached manifests.
- iCloud traversal uses actual nested URLs, maps placeholders to logical names, and skips symlinks. Repeated directory names cannot recurse indefinitely.
- Local-to-iCloud migration fails on enumeration or move errors and never recursively deletes the source root. Partially completed moves can be retried without discarding remaining files.
- Native editor saves retain recovery drafts on failure and reject stale document callbacks. iOS reports success only after writing; macOS saves the selected file rather than redirecting a selected `main.jsx` to another manifest entry.
- Ollama has an explicit profile with no required API key, server model discovery, editable model name, and Mac/iPhone connection guidance. Explicit no-auth requests omit Authorization entirely.
- Compatible API endpoints validate HTTP(S) base addresses and preserve gateway path prefixes. Endpoint changes clear credentials; OAuth cannot be sent to another host. Adding PCC during migration preserves the user's existing active profile.
- PCC stays explicit: no silent third-party fallback, and generic system failures show recovery guidance. Apple on-device inference and new deep-link APIs are outside this maintenance patch.

## Regression coverage

New deterministic cases cover failed cache preparation, replacement and incomplete snapshots, alternate entry plus manifest eviction, malformed-manifest preservation, nested traversal/cycles, failed migration enumeration and collision preservation, failed saves/stale document IDs, canceled-generation isolation, Ollama no-key configuration, endpoint validation, credential clearing, compatible request paths/headers, and preserving the active AI profile.

An opt-in native Ollama test reads `/v1/models` and generates a response through `AIClient` using an existing local model. Run with `TEST_RUNNER_AI_OLLAMA_TEST_URL` and `TEST_RUNNER_AI_OLLAMA_TEST_MODEL`. No model download is required by the test.

## Verification record

Validation results and CI link are recorded in the pull request. Local logs are `/tmp/scriptwidget-stability-gate-final.log`, `/tmp/scriptwidget-stability-ipad.log`, and `/tmp/scriptwidget-ollama-final.log`; Xcode result bundles are under `/tmp/scriptwidget-release-readiness/`.

- Focused native cache/AI regression run passed, including a real no-key Ollama response on the isolated local test server (`qwen2.5:1.5b`).
- macOS settings were manually exercised: add Ollama, load installed models, choose one, test connection; result was `pong`. Final screenshot review found and fixed a clipped authentication label in the narrow window. The macOS app scheme was rebuilt and the corrected label was visually verified; before/after screenshots are in the task.
- Final `release-readiness.sh` passed on Xcode 27: editor 29 tests, macOS 160 passed / 6 opt-in skipped, iPhone 163 passed / 6 opt-in skipped, plus iOS/macOS app builds and metadata/generated-bundle checks.
- Final `ipad-icloud-tests.sh` passed: iPad 163 passed / 6 opt-in skipped. Deterministic iCloud-state coverage passed; signed-container tests were not enabled.
- The final direct URLSession transport also passed the opt-in native Ollama test with `qwen2.5:1.5b`.
- Skipped opt-in cases require PCC, external AI credentials/evals, or signed one/two-device iCloud setup; the regular suite also skips the separately executed Ollama live test.
- A PCC connection attempt in the unsigned development app returned a Foundation Models system error. This does not certify distribution entitlement access. A signed build's PCC live test remains required before describing PCC as verified for release.
- Physical iPhone Lock Screen/Dynamic Island, signed iCloud eviction over cellular, and cross-device convergence were not executed. Simulator/build/unit results do not replace those checks.

## Related reports

[Issue #6](https://github.com/everettjf/scriptwidget/issues/6) reports iCloud/cellular file availability and is related to the cache path. The supplied Discord screenshot has no app build, package, or device logs, so its exact cause is not claimed as reproduced. [Issue #45](https://github.com/everettjf/scriptwidget/issues/45) concerns macOS background rendering; its previously landed fix remains covered by existing checks and is not changed here.
