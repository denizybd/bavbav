# Desktop Companion safety snapshot

`Safety.swift` and `Geometry.swift` are an unmodified snapshot of the user's
Desktop Companion sources from `/Users/deniz2/Documents/MCP/desktop-companion`,
integrated on 2026-10-09. The original project and its saved keys are unchanged.

The Bavbav adapter uses the revocation epoch and local-stop barrier only. It
does not call `grantLocalControl`, import `CompanionNative`, expose input tools,
or change the original demo-only control allowlist. Window sharing has its own
explicit selection, identity validation, one-shot preview and send consent.

This notice does not relicense the original project or claim production desktop
control, native ChatGPT Voice, permission acceptance, or real image delivery.
