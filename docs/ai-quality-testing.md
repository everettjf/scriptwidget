# AI widget quality regression

`Scripts/ai-quality.sh` runs the real app AI client and generate → execute → repair loop against eight synthetic offline requests, twice each by default, with a four-iteration cap. Cases cover small, medium, large, extra-large, inline, circular and rectangular families, including Chinese text, rings, stats and a native chart. No user widgets are sent to the provider.

## Run locally

Use a macOS development environment with Xcode and an existing provider key. Pass credentials through environment variables; never commit a key or paste one into a command literal. For example, if your shell already exports `DEEPSEEK_API_KEY`:

```sh
ROCKY_OPENAI_APIKEY="$DEEPSEEK_API_KEY" \
ROCKY_OPENAI_BASEURL=https://api.deepseek.com \
ROCKY_OPENAI_MODEL=deepseek-flash \
./Scripts/ai-quality.sh
```

Discover the actual model ID from your server. The current DeepSeek presets were checked against `/v1/models` and [DeepSeek's official documentation](https://api-docs.deepseek.com/). Live runs use provider tokens. `AI_QUALITY_ATTEMPTS` defaults to 2 and is clamped to 1–3; requests are sequential and each attempt uses at most 4 model calls.

Artifacts default to the git-ignored `__Release/ai-quality/<timestamp>/`. Override with an absolute `AI_QUALITY_OUTPUT`. Each run writes generated JSX, `quality.json`, configuration, two native screenshots per successful attempt, `vision.json` and an offline `index.html` review page. Artifacts remain local; the script never uploads them.

The default CI suite skips the opt-in live test. Deterministic frame and appearance regressions run in the normal suite without a key.

## Compare without another model call

Replay a prior run's JSX through the current runtime. This separates renderer fixes from randomness in generation and does not require credentials:

```sh
AI_QUALITY_REPLAY=/absolute/path/to/baseline \
AI_QUALITY_OUTPUT=/absolute/path/to/replay \
./Scripts/ai-quality.sh
```

The attempt count must match the saved baseline. Missing input files fail explicitly. Each appearance re-executes the same generated source under the matching native appearance; merely recoloring the screenshot would not exercise `$device.isdarkmode()`.

## Interpret results

- Runtime checks: the agent returned a real element without an execution error.
- Semantic checks: requested labels/values are present in the element tree, and requested ring/progress/chart tags exist. These checks alone cannot prove visibility or correctness of every data field.
- Screenshot checks: native SwiftUI snapshots at the declared size in light and dark appearances. Vision OCR marks missing expected text for review; punctuation, small text and Chinese recognition can produce false positives.
- Visual review: inspect clipping, overlap, contrast, layout density, chart axes and the requested information. Do not label an image aesthetically correct simply because it rendered or OCR passed.

Generated widgets are untrusted scripts and continue to run under the existing runtime limits. The suite uses fixed data to avoid confounding model quality with external service availability. It does not certify real WidgetKit lock-screen rendering, HealthKit/location access, PCC entitlements, live data accuracy or all possible prompts.

If the run fails, inspect the saved report before retrying. The shell command preserves the XCTest failure exit status even when producing a review page. Do not loosen runtime limits or remove failing expectations to improve a reported pass rate.
