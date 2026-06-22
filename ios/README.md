# ios/ — NVP Node worker app (SwiftUI)

The iPhone worker app. Open in Xcode on a Mac, or let CI build an unsigned IPA.

## Project generation (XcodeGen)

There is **no checked-in `.xcodeproj`** — it's generated from `project.yml` so
the repo stays clean and CI is reproducible.

```bash
brew install xcodegen
cd ios
xcodegen generate     # creates NVPNode.xcodeproj
open NVPNode.xcodeproj
```

Set the coordinator URL in-app (Settings) or edit `Config.defaultCoordinatorURL`.

## What it does (v0)

- Onboarding → registers the device (Curve25519 keypair in Keychain, API key from
  the coordinator).
- **Worker** tab: big “Become a worker” toggle → runs the loop `next → infer →
  submit`, respecting foreground + thermal + charging state.
- **Earnings** tab: live balance in **real USD**, cumulative-credits sparkline,
  ledger history, and **Request a withdrawal** (creates a `requested` payout).
- **Settings**: coordinator URL, device info, sign out.

## Inference engine

`InferenceEngine` is a protocol. The app ships **real on-device inference** by
default: `MLXInferenceEngine` runs an LLM on the iPhone GPU via
[MLX Swift](https://github.com/ml-explore/mlx-swift-lm) (products `MLXLLM` +
`MLXLMCommon`, pinned in `project.yml`). It loads **Qwen2.5-0.5B-Instruct-4bit**
natively (docs/06 §8.3), greedy/deterministic (temperature 0). The model is
downloaded from Hugging Face on first run. `StubInferenceEngine` remains for
testing the loop without a model.

- **No Mac needed**: the GitHub Action builds the IPA with MLX included, on a
  macOS runner. Run on a real iPhone 15 Pro+ (≥8 GB RAM); MLX needs a device GPU
  (it won't run inference in the iOS Simulator).
- **Gemma 4 E2B** (the v0 target): switch `Config.mlxModelId` to the Gemma quant
  and wire the Swift Gemma-4 port (`docs/06` §2), building the prompt with
  `GemmaPrompt.build` (literal template, `docs/06` §3). If the port resists,
  `docs/06` §9 Plan B = keep the native model.

> For canary parity, generate expected outputs with the same model via Python
> `mlx-lm` (`scripts/gen_canaries.py`) and re-seed.

## Unsigned IPA in CI

`.github/workflows/ios-unsigned-ipa.yml` builds an **unsigned** `.ipa` on a macOS
runner (triggers: manual, push to `ios/**`, tag `v*`). The IPA is uploaded as a
build artifact and attached to releases on tags.

> Unsigned = it won't install on a stock device as-is. Sideload with your own
> signing (e.g. Sideloadly/AltStore) or sign it in Xcode with your Apple ID to
> run on your iPhone. Real distribution needs a signed build (Apple Developer
> account) — out of scope for v0.
