# Bavbav Workspace

Workspace is a private collaboration module hosted by Bavbav. Its SwiftUI/AppKit views run in Bavbav's process; its packaged Node engine communicates over private stdio. It does not launch a second Workspace GUI app.

## Source ownership

| Repository | Canonical responsibility |
| --- | --- |
| `denizybd/bavbav` (public) | Main application, Workspace host adapter, menus, lifecycle, and public build. |
| `denizybd/iki-workspace` (private) | Workspace views, signed snapshots, P2P engine, runtime staging, private installer, and integration verification. |

The private repository is still required. An integrated app bundle does not make its source repository redundant. Keep it active until every private component and its history has an explicitly chosen replacement.

## Public build

The default is `BAVBAV_WITH_WORKSPACE=0`. A fresh public clone builds without private files, does not register the Workspace shortcut, and does not start or read the paired Workspace store. Public downloads contain this variant.

## Authorized integrated build

From an authorized clone of the private Workspace repository, prepare the native engine and stage its sources into a Bavbav checkout:

```sh
npm ci
zsh scripts/build-native.zsh
node scripts/stage-bavbav.mjs /absolute/path/to/bavbav
cd /absolute/path/to/bavbav
BAVBAV_WITH_WORKSPACE=1 BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh
```

The private repository also supplies a pinned, end-to-end `scripts/build-bavbav.zsh` command. See that repository's README for the exact source revision.

Staging writes ignored `Sources/IkiWorkspaceKit/` and `Vendor/IkiWorkspace/Resources/` directories. Set `BAVBAV_WITH_WORKSPACE=1` for direct Swift commands too. Packaged builds fail if a selected Workspace runtime is incomplete; `IKI_WORKSPACE_APP` can explicitly select a matching prepared engine bundle.

Use the [signing guide](LOCAL-SIGNING.md) for the local signing identity. Development-only ad-hoc builds require `BAVBAV_ALLOW_ADHOC_SIGNING=1` explicitly.

## Existing data and lifecycle

Authorized builds retain `~/Library/Application Support/IkiWorkspace`. Updating the app does not replace pairing identities, chats, or project snapshots. Do not copy this data directory into a release.

`⌘7` and the Workspace menu open the same native window. Closing that window keeps the peer engine alive; quitting Bavbav closes its client. Existing custom `⌘7` bindings are preserved, with Workspace remaining accessible from the menu.

## Verification

```sh
"/absolute/path/Bavbav.app/Contents/MacOS/Bavbav" \
  --workspace-ui-check \
  --workspace-report /tmp/bavbav-workspace-report.json \
  --workspace-render /tmp/bavbav-workspace.png
```

This diagnostic uses an isolated temporary directory and offline engine. It checks the native window, shortcut, menu, engine startup, and shutdown. It does not access the paired user store. Its rendered image is not proof of physical input or a live connection between two devices.

A private installer may carry a peer-specific connection capability. Keep that distribution private; public releases must be built with Workspace disabled.
