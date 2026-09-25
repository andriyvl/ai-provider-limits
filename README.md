<p align="center">
  <img src="assets/logo.svg" width="140" alt="AI Limits app icon">
</p>


# AI Limits

A lightweight, native macOS Menu Bar app to monitor real-time usage quotas, session caps, weekly rate limits, and credits across AI coding assistants and models.

Supported providers:
- **Google Antigravity** (Gemini models: 5-hour rolling session & weekly quota)
- **OpenAI Codex** (Codex & ChatGPT models: 5-hour window, weekly quota, credits)
- **Anthropic Claude** (5-hour and 7-day usage windows, plus Sonnet and Opus caps)
- **Cursor** (Cursor Models & Other Models usage allowance, credits, subscription renewal date)
- **OpenRouter** (Account credit balance, active API key spend limit & reset schedule, UTC daily usage)

---

## Highlights

- **Zero API Key Configuration**: Reads active local workstation session credentials directly from existing developer tool logins (`~/.codex/auth.json`, `~/.claude/.credentials.json`, Cursor local state, Antigravity local app storage, or local OMP credential storage in `~/.omp/agent/agent.db` / `OPENROUTER_API_KEY`).
- **Direct Usage & Dashboard Links**: Click the link icon next to any provider header to jump straight to its web usage or spending dashboard.
- **100% Private & Local**: Communicates directly from your Mac to official provider endpoints. No middleman servers, analytics, or third-party telemetry.
- **Native SwiftUI Menu Bar Extra**: Lives unobtrusively in your menu bar. Click to inspect live linear progress bars, exact percentage remaining, countdown timers, and expiration badges.
- **Subscription Renewal & Plan Badges**: Formatted plan names in headers (e.g. ChatGPT Pro, Claude Pro, Google AI Pro) and color-coded badges (`till MMM d`) highlighting days remaining until billing cycle renewal.
- **Customizable Order & Toggles**: Reorder providers and hide inactive ones directly in settings.
- **CLI Terminal Preview**: Inspect limits in any terminal using Unicode progress bars.

---

## How Limit Values Are Retrieved

AI Limits runs 100% locally on your workstation. It does not use intermediate proxy servers, cloud scrapers, or third-party telemetry. It reads active session credentials already stored by your installed developer tools and queries the official provider endpoints directly:

| Provider | Local Credential Discovery | Upstream API Endpoint | Values & Metrics Extracted |
|---|---|---|---|
| **Google Antigravity** | `~/.omp/agent/agent.db` (`google-antigravity`) or local fallback `~/Library/Application Support/Antigravity/app_storage.json` | `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | Gemini 5-hour rolling session & weekly quota, Claude & GPT 5-hour & weekly limits, remaining percentages, reset timestamps, and model credit overage toggles. |
| **OpenAI Codex** | `~/.codex/auth.json` or `~/.omp/agent/agent.db` (`openai-codex`), prioritised by latest unexpired JWT token | `GET https://chatgpt.com/backend-api/wham/usage` (passing `ChatGPT-Account-Id` when present) | Plan type (`ChatGPT Plus`, `ChatGPT Pro`, `Team`, `Enterprise`), primary 5-hour window, secondary weekly quota, reset timestamps, and remaining credits count. |
| **Anthropic Claude** | `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) | `GET https://api.anthropic.com/api/oauth/usage` | `five_hour` session window, `seven_day` weekly window, `seven_day_sonnet` and `seven_day_opus` caps, reset timestamps/durations, and `extra_usage.balance`. |
| **Cursor** | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`ItemTable`) or `~/.omp/agent/agent.db` | `GET https://cursor.com/api/usage-summary`<br>`POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance`<br>`POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` | Cursor Models allowance, Other Models allowance, Grok Bot weekly allowance & reset timestamp (`nextResetTimestampUtc`), on-demand spend, and billing cycle end date (`billingCycleEnd`). |
| **OpenRouter** | `OPENROUTER_API_KEY` process environment or newest active `openrouter` entry in `~/.omp/agent/agent.db` | `GET https://openrouter.ai/api/v1/credits`<br>`GET https://openrouter.ai/api/v1/key` | Net available USD account balance (`total_credits - total_usage`), active API key spend limit & remaining balance, limit reset period, and UTC daily spend (`usage_daily`). |

### Offline & Fallback Behavior
- If an active network call fails (e.g. transient network drop or rate limit), the app maintains your last known cached snapshot from local storage so the menu bar doesn't flicker or reset to empty.
- When credentials are completely missing for an unconfigured provider, that provider yields an inactive snapshot without making outbound requests.

---

## How it looks
<p align="center">
  <img src="assets/overview.png" width="360" alt="AI Limits menu bar overview">
  <img src="assets/settings.png" width="360" alt="AI Limits settings view">
</p>

## Requirements

- macOS 14.0 or later
- Apple Silicon (arm64) or Intel (x86_64)
- Swift 6.0+ / Xcode 16+

---

## Getting Started

### Build and Launch

Clone the repository and run:

```bash
make run
```

This compiles the release binary and opens `dist/AI Limits.app`.

### Build App Bundle Only

```bash
make build
```

The self-contained app bundle will be placed in `dist/AI Limits.app`.

### Terminal Preview

To inspect current limits without launching the GUI menu bar app:

```bash
make preview
```

or:

```bash
swift run provider-limits
```

### Run Tests

```bash
swift test
```

---

## Architecture

- **`Sources/ProviderLimitsCore`**: Core domain logic, normalized data models (`ProviderUsageSnapshot`, `LimitMetric`), provider clients (`AntigravityProvider`, `CodexProvider`, `ClaudeProvider`, `CursorProvider`, `OpenRouterProvider`), and SwiftUI progress bar components.
- **`App/`**: Native macOS `MenuBarExtra` host application (`MenuBarHostApp.swift`, `MenuBarContentView.swift`).
- **`Sources/ProviderLimitsCLI`**: Terminal preview tool for fast headless inspection.

---

## Author & License

Created by Andriy Viychuk ([@andriyvl](https://github.com/andriyvl)).

AI Limits is licensed under the [Apache License 2.0](LICENSE).

You may use, modify, fork, and redistribute it, including commercially. Redistributions and forks must preserve the license, copyright, and attribution notice in [NOTICE](NOTICE). Apache 2.0 does not require visible in-app credit.
