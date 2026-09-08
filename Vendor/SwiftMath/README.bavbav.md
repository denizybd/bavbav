# SwiftMath 1.7.3 (vendored)

Upstream: https://github.com/mgriebling/SwiftMath
Commit: fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7
License: MIT (LICENSE). Fonts include their original licenses in mathFonts.bundle.

The upstream Sources directory is preserved, with a small macOS packaging patch:
MTFont.swift and MathFont.swift use Bundle.bavbavMathResources. The helper in
BavbavResourceBundle.swift first locates the signed app's Contents/Resources
bundle, then falls back to SwiftPM's Bundle.module during development.

Why: the generated SwiftPM accessor looks at the .app root, where an extra bundle
or symlink causes macOS codesign to reject the application as unsealed. Relying
on its build-directory fallback works only on the development machine.

When upgrading, replace upstream Sources, reapply these three lookup changes,
retain this helper, and run BAVBAV_RICH_MESSAGE_CHECK against the packaged app.
