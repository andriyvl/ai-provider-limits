# Contributing to AI Limits

Thank you for your interest in contributing to AI Limits! We welcome contributions from the community—bug fixes, new provider integrations, performance improvements, and documentation polish.

---

## Getting Started

### Prerequisites

- **macOS**: 14.0 (Sonoma) or later
- **Architecture**: Apple Silicon (arm64) or Intel (x86_64)
- **Toolchain**: Swift 6.0+ / Xcode 16+

### Local Setup

1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/<your-username>/ai-provider-limits.git
   cd ai-provider-limits
   ```
3. Create a feature branch off `main`:
   ```bash
   git checkout -b feature/my-new-feature
   ```

---

## Development & Build Commands

- **Run Tests**:
  ```bash
  swift test
  ```
  Make sure all unit tests pass before submitting changes.

- **Build Standalone App**:
  ```bash
  make build
  ```
  or directly:
  ```bash
  ./scripts/build-app.sh
  ```
  This creates `dist/AI Limits.app`.

- **Run the App Locally**:
  ```bash
  make run
  ```

- **CLI Terminal Preview**:
  ```bash
  swift run provider-limits
  ```
  Inspect live quotas directly in the terminal without launching the GUI menu bar app.

---

## Contribution Guidelines

1. **Pull Requests Only**: Direct pushes to `main` are protected. All contributions must be submitted as Pull Requests from your fork or a feature branch.
2. **Test Coverage**:
   - Every new provider client or metric parser must include unit tests in `Tests/ProviderLimitsCoreTests/`.
   - Bug fixes should include a regression test ensuring the bug cannot reappear.
3. **Privacy & Security**:
   - Never commit API keys, personal session tokens, or internal workstation paths.
   - All network calls must communicate directly with official provider endpoints—no third-party telemetry, tracking, or intermediary proxies.
4. **Code Style**:
   - Write clean, modern Swift using Swift Concurrency (`actor`, `async/await`, `Sendable`).
   - SwiftUI components should align with the established design theme (`LiquidGlassTheme`).

---

## Submitting a Pull Request

1. Push your branch to your fork:
   ```bash
   git push origin feature/my-new-feature
   ```
2. Open a Pull Request against `andriyvl/ai-provider-limits:main`.
3. Provide a clear description of:
   - What changed and why.
   - Any new provider endpoints or metric fields added.
   - Verification steps and test results.
