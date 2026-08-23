# Apple Private Cloud Compute AI plan

## Decision

Adopt Apple Foundation Models as a new, Apple-first AI backend, with Private
Cloud Compute (PCC) as the preferred model when it is available. Do not remove
the existing OpenAI-compatible backend yet.

PCC can remove API-key setup for eligible users, but it is not a universal
replacement today. It requires iOS, iPadOS, or macOS 27 or later, an Apple-
managed entitlement, Apple Intelligence availability, network access, and
remaining daily quota. ScriptWidget must keep a functional fallback for older
devices, unsupported regions, and exhausted quotas.

## What Apple now makes possible

Apple exposes `PrivateCloudComputeLanguageModel` through the Foundation Models
framework. It conforms to the same `LanguageModel` protocol as the on-device
`SystemLanguageModel`, so both can be passed to `LanguageModelSession`.

The PCC model provides a 32K context window and multiple reasoning levels. The
on-device model works offline and without a daily quota, but has a 4K context
window and no reasoning mode. PCC requests do not require an API key from the
person using the app.

Access is conditional:

- The developer must be in the App Store Small Business Program.
- The developer's apps must have fewer than two million first-time downloads.
- Apple must assign the `com.apple.developer.private-cloud-compute` managed
  entitlement to the developer account.
- PCC is available to third-party apps on iOS, iPadOS, macOS, watchOS, and
  visionOS 27 or later where Apple Intelligence is available.
- PCC has a per-person daily quota. Apple provides quota status and a system
  path for iCloud+ subscribers to receive more access.
- If eligibility is later lost, Apple allows six months to migrate to another
  solution.

Primary references:

- [Accessing Private Cloud Compute](https://developer.apple.com/private-cloud-compute/)
- [Adding server-side intelligence with Private Cloud Compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Private Cloud Compute security guide](https://security.apple.com/documentation/private-cloud-compute/)

## Fit with ScriptWidget

The existing `AgentLoop` already separates prompt construction, model calls,
runtime execution, and repair iterations. The main coupling is that `AIClient`
directly constructs a SwiftOpenAI request and `AIProfile.isConfigured` assumes
every usable provider has a credential.

The current prompt reference can grow to 60,000 characters before it falls
back to a curated subset. That is a reasonable fit for PCC's 32K context after
token-budget validation, but it cannot fit reliably in the on-device model's
4K context. A compact reference profile is required before the on-device model
can be a dependable fallback.

The current maximum of 20 repair iterations also needs a provider-specific
budget. Repeated PCC calls can consume a person's daily quota even when the
widget never converges.

## Proposed architecture

### 1. Make the model client provider-neutral

Introduce an internal client protocol that accepts `[AIMessage]` and returns
`AIChatResult`. Keep the existing OpenAI implementation and add an Apple
Foundation Models implementation.

The Apple implementation should create a `LanguageModelSession` with:

```swift
if #available(iOS 27.0, macOS 27.0, *) {
    LanguageModelSession(model: PrivateCloudComputeLanguageModel())
} else {
    LanguageModelSession(model: SystemLanguageModel.default)
}
```

The production implementation must also check model availability, PCC quota,
and the managed entitlement. OS availability alone is not sufficient.

### 2. Represent backend choice separately from authentication

Add a backend kind such as `appleIntelligence` or `openAICompatible` to
`AIProfile`. Apple profiles are configured by capability and availability, not
by the presence of an API key. Preserve decoding of existing profiles as
`openAICompatible` so this remains an additive migration.

No Apple session data, prompts, or generated responses should be written to
profiles, UserDefaults, logs, Skills, or Gallery packages.

### 3. Select the safest available model

Use this order for the default Apple profile:

1. PCC when the managed entitlement, OS, model availability, network, and
   quota allow it.
2. The on-device system model when it is available and the compact prompt fits.
3. A configured OpenAI-compatible profile, if the user has opted into one.
4. A clear capability message explaining why AI generation is unavailable.

Do not silently send a prompt to a third-party provider after PCC fails. A
person must explicitly configure and select that fallback because its privacy
contract differs from Apple's.

### 4. Add prompt and iteration budgets

- Add a compact API reference designed for the 4K on-device context.
- Measure the assembled prompt before starting a session.
- Start PCC and on-device generation at three repair iterations rather than
  inheriting the current maximum of 20.
- Surface quota and availability as product state, not as a generic network
  error.
- Treat token counts as optional because Foundation Models does not expose the
  same usage object as the OpenAI-compatible API.

### 5. Keep Apple AI out of widget extensions

Run Foundation Models only from the iOS or macOS Studio/app process. Generated
JSX continues through the existing sandboxed validation path before it is
saved. Widget extensions must not perform model inference or gain the PCC
entitlement.

## Rollout plan

### Phase 0: account and quality gate

- Confirm Small Business Program enrollment and the two-million-download
  eligibility threshold.
- Request the PCC managed entitlement from Apple.
- Add a representative evaluation set for fresh generation, repair, refine,
  and Copilot flows.
- Compare PCC output quality and convergence against the current baseline.

Do not ship a PCC control before Apple assigns the entitlement. Adding an
unapproved entitlement would break signing rather than create a usable model.

### Phase 1: on-device Apple backend

- Land the provider-neutral client boundary.
- Add the compact 4K prompt and `SystemLanguageModel` implementation.
- Offer Apple Intelligence as a zero-key option on supported OS 26 devices.
- Retain the OpenAI-compatible provider unchanged.

This phase validates the application architecture without depending on cloud
entitlement approval, although its smaller model may not meet the quality bar
for complex widget generation.

### Phase 2: PCC beta

- Compile the PCC adapter with the iOS/macOS 27 SDK while retaining availability
  guards and older-OS fallback.
- Add the entitlement only to the iOS and macOS app targets after approval.
- Display quota status before generation and map quota errors to actionable UI.
- Make Apple Intelligence the first-run default only after evaluation results
  meet the existing agent-loop baseline.

### Phase 3: simplify onboarding

- Remove API-key instructions from first-run UI for supported Apple devices.
- Move third-party providers under an optional advanced/fallback section.
- Keep existing Keychain-backed profiles and their migration path.

## Required validation

- Unit tests for existing profile migration and Apple profiles without secrets.
- Deterministic client tests for PCC available, unavailable, quota-warning,
  quota-exhausted, offline, and cancellation states.
- Prompt-size tests for both 4K and 32K model budgets.
- Agent-loop evaluation comparisons for generation success and repair count.
- iOS and macOS app builds on both the oldest supported SDK and the iOS/macOS
  27 SDK.
- Signed TestFlight or ad hoc testing after entitlement approval. Simulator-only
  testing is not sufficient evidence that PCC access works.

## Recommendation

Proceed with the provider abstraction and on-device evaluation now, and apply
for the PCC entitlement in parallel. Make PCC the default only after entitlement
approval and quality/quota evaluation. This reaches the zero-key onboarding goal
without making AI generation disappear for users whom PCC cannot serve.
