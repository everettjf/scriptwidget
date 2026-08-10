# Runtime Concurrency Audit

This audit records the Stage 6 decision for the architecture refactoring plan.
The goal is to protect runtime isolation without changing established widget
execution, timeout, or cancellation behavior without evidence of a defect.

## Evidence

- `ScriptWidgetRuntime` owns its `JSContext`; runtime state is associated with
  that context and JS exports retrieve it through `JSContext.current()`.
- Mutable execution-session state, diagnostics snapshots, fetch state, and
  image-loading coordination use explicit locks or per-execution semaphores.
- A deterministic runtime test executes eight runtimes concurrently with unique
  environment values and verifies that every rendered result stays isolated.
- `ScriptWidgetRuntimeTests` builds successfully with
  `SWIFT_STRICT_CONCURRENCY=complete` and emits no concurrency diagnostics.

## Decision

Keep the existing execution model in this stage. Replacing the synchronous
wrappers, timeout semaphores, or JavaScriptCore scheduling would change mature
runtime semantics while the audit and regression test show no isolation fault.
This is intentionally a verification change, not a concurrency rewrite.

Revisit the execution model only when one of these conditions is met:

- a reproducible cross-runtime state leak or data race is found;
- Swift 6 language mode produces an actionable diagnostic in runtime sources;
- profiling identifies the current synchronization as a material bottleneck;
- JavaScriptCore ownership requirements change on a supported OS version.

Any future migration must preserve cancellation, timeout, logging, package
namespace, and environment isolation tests before it replaces the current path.
