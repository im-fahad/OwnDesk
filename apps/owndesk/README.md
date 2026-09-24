# OwnDesk

One app per Mac. It can control another Mac, be controlled by one, or both at the same time.
The libraries in `apps/mac-agent` and `apps/mac-controller` provide the two halves, and their
headless CLIs remain for testing.

[../../README.md](../../README.md) is the guided tour: the technology, the full flow from pairing to
a moving picture, and the user guide. This file is the app's own reference.

## Build and install

```sh
scripts/build-apps.sh owndesk      # dist/OwnDesk.app, ad-hoc signed; no certificate needed
scripts/install-owndesk.sh         # to ~/Applications, started in the menu bar and again at login
scripts/install-owndesk.sh --stage # copy it into place but run nothing, for a Mac you are away from
scripts/install-owndesk.sh --replace-agent   # also stop and remove an old v0.1 "PRC Agent" install
```

| Flag | Effect |
|---|---|
| `--name <text>` | Name other Macs see. Default: this Mac's name. |
| `--data-dir <path>` | Identity, peers and settings. Default `~/Library/Application Support/OwnDesk` |
| `--port <n>` | Port to listen on when hosting. Default 47500. |
| `--host` | Start with hosting on, whatever the saved setting says |
| `--background` | Start in the menu bar with no window, as the login copy does |
| `--file-identity` | Development: keep the identity in the data folder rather than the Keychain |
| `--synthetic-screen` | Test: stream a generated pattern instead of the screen |

## The two directions

Hosting is off until you switch it on, so installing this never makes a Mac remotely controllable
on its own. The switch is in the sidebar under **This Mac** and in the menu bar panel. Turning it on
is also what asks for Screen Recording and Accessibility: a Mac you only control *from* never sees
those prompts.

Pairing records both directions at once, which costs nothing in trust because a single pairing
already exchanges both public keys and both people compare fingerprints. What each Mac may do is
then two separate permissions you can withdraw one at a time, from a peer's context menu:

- **This Mac may control it**, which puts it under "Macs you can control".
- **It may control this Mac**, which lets it open a session here when hosting is on.

Pair from either end: **Show a code** on one Mac and paste it on the other. A phone pairs from the
same code, by scanning the QR with its camera. **Show full screen** fills the display with the code
for a phone that struggles with the small one; it closes on a click, on Esc, or by itself when the
phone's request arrives.

**Unpair…** in a device's right-click menu, or the ⓧ that appears on hover, ends the pairing on both
sides, and both must pair again. Another Mac is told at once with a signed `UNPAIR` when it can be
reached; a phone finds out the next time it tries to connect, when this Mac turns it away. If the
other device cannot be reached, OwnDesk says so, and you unpair it there too.

## The window, and the menu bar

The app lives in the menu bar and only claims a Dock icon while a window is open, so a Mac started
at login adds nothing to the Dock, and an open window can still take keyboard focus.

| Action | What happens |
|---|---|
| Close the window, or ⌘W | It goes away, and so does the Dock icon. The menu bar item stays, and hosting keeps running. |
| **Open OwnDesk…** in the menu bar | The window comes back |
| Double click the header | Zooms, or whatever "double-click a window's title bar to" is set to in System Settings |
| Drag the header | Moves the window |
| **Quit** | Really quits: the launch agent brings the app back after a crash, never after Quit |

## Where its data lives

`~/Library/Application Support/OwnDesk`: the identity, the peer list, settings, and `control.json` for
the script channel. Logs are in `~/Library/Logs/OwnDesk`. Nothing there is a secret except the identity,
which is an opaque Secure Enclave reference on a Mac that has one, and the token in `control.json`.

## Upgrading from PRC

OwnDesk was called PRC until September 2026. `scripts/install-owndesk.sh` stops and removes
`PRC.app`, and the first launch takes over `~/Library/Application Support/PRC` and the old app's
settings, so the Mac keeps its identity, its pairings, and its hosting switch. macOS treats the new
bundle id as a new app, so grant Screen Recording and Accessibility again. The phone app has a new
application id too: install it, pair it once more, and forget the old phone entry on each Mac.

## Migrating from the v0.1 split apps

The first launch brings forward whichever of the old v0.1 apps ran on this Mac: its identity, so other
Macs still recognise it, and its pairings. The old stores recorded only one direction, so after
upgrading you can still control what you could before. To add the reverse, either pair once more or
turn on the matching permission on each Mac.

## Driving it from a script

`control.json` in the data folder carries a loopback port and a token, and the CLI in
`apps/mac-controller` speaks to it:

```sh
owndesk-controller-cli app status | peers | hosting off
owndesk-controller-cli app pending | deny
owndesk-controller-cli app connect <peer> [address] | disconnect | end-incoming | stats
owndesk-controller-cli app allow <peer> control-us|we-control off | unpair <peer> | forget <peer>
owndesk-controller-cli app quality <preset> | panels [sidebar|log|text] | quit
```

Any program running as you can read that token, and OwnDesk holds Screen Recording and Accessibility.
So the channel can only take access away. Switching hosting on, showing or using a pairing code,
approving a pairing, and granting a permission are clicks in the app. On a Mac without a display,
make them over Screen Sharing.
