# Offline Thunderbolt connection

The full private Workspace build of Bavbav 0.16.0 (74) integrates the cable
transport into the same application. A public-source build intentionally does
not contain the separately distributed private Workspace component.

## Requirements

- Two previously paired Deniz/Emir Macs, running matching current full builds.
- A Thunderbolt-capable cable between Thunderbolt ports. A USB-C connector or
  charging indication alone does not establish a Thunderbolt data link.
- An active macOS Thunderbolt Bridge with an IPv4 address on each Mac.
- Local Network permission for the actual installed Bavbav application when
  macOS requests it. The app cannot grant this permission to itself.

Open Workspace with Command-7 and select **Thunderbolt ile bağlan** on both
Macs. This explicit choice is saved across relaunches. Cable discovery starts
before public Internet discovery and uses the existing paired identities;
Internet access is not required for the cable channel itself.

The first cable implementation supports IPv4. It reports a missing cable,
interface, address, or connection error rather than treating a button click as
an authenticated connection. Do not change or delete pairing data to repair a
cable/IP problem.

See Apple's [IP over Thunderbolt instructions](https://support.apple.com/guide/mac-help/ip-thunderbolt-connect-mac-computers-mchld53dd2f5/mac).

## Preventing an old engine from shipping in a new host

The full-build resource contract requires Workspace engine 0.7.3 or later,
the Thunderbolt and persistent-service modules, and embedded application
metadata that matches the host version/build. Missing, symlinked, malformed or
stale resources cannot pass the native package check. Publishing source code
alone does not update a running old application or its background service.

Use the existing **Bavbav Local Code Signing** identity for the unified package;
do not create another certificate for each build. Certificate identity,
application installation, macOS privacy permission, and an actual cable
connection are distinct checks. The local certificate is not Apple Developer
ID signing or notarization. See [local signing](LOCAL-SIGNING.md).

## Acceptance is separate from fixtures

`BAVBAV_WORKSPACE_RESOURCE_CHECK=1` validates resource contracts with isolated
filesystem fixtures and, for a full app, its actual embedded resources.
Canonical Workspace tests separately exercise multicast/TCP/Noise over
loopback, paired identity checks, unplug/reconnect and saved enablement.
Neither level proves a physical two-Mac Thunderbolt connection or GUI privacy
permission: Terminal-launched tools can have different network authorization.

Installed-user acceptance must confirm both Macs report the expected version,
the OS detects an active cable bridge, and Workspace reports authenticated
`transport: thunderbolt`. Then verify chat and a small file transfer while
public Internet access is unavailable, including disconnect and reconnect.
Do not disconnect a user's active Internet or workloads without their approval.
