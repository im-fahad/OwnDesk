# PRC

One app per Mac. It can control another Mac, be controlled by one, or both at the same time.
The split `mac-agent` and `mac-controller` apps are what this replaces; their libraries still
provide the two halves, and their headless CLIs remain for testing.

## Build and install

```sh
scripts/build-apps.sh prc      # dist/PRC.app, ad-hoc signed; no certificate needed
scripts/install-prc.sh         # to ~/Applications, started in the menu bar and again at login
scripts/install-prc.sh --stage # copy it into place but run nothing, for a Mac you are away from
scripts/install-prc.sh --replace-agent   # also stop and remove the older split agent
```

| Flag | Effect |
|---|---|
| `--name <text>` | Name other Macs see. Default: this Mac's name. |
| `--data-dir <path>` | Identity, peers and settings. Default `~/Library/Application Support/PRC` |
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

Pair from either end: **Show a code** on one Mac and **Use a code** on the other.

## Migrating from the split apps

The first launch brings forward whichever of the old apps ran on this Mac: its identity, so other
Macs still recognise it, and its pairings. The old stores recorded only one direction, so after
upgrading you can still control what you could before. To add the reverse, either pair once more or
turn on the matching permission on each Mac.

## Driving it from a script

`control.json` in the data folder carries a loopback port and a token, and the CLI in
`apps/mac-controller` speaks to it:

```sh
prc-controller-cli app status | peers | hosting on|off
prc-controller-cli app offer-pairing | pending | approve | deny | pair <payload|@file> [address]
prc-controller-cli app connect <peer> [address] | disconnect | end-incoming
prc-controller-cli app allow <peer> control-us|we-control [on|off] | forget <peer>
prc-controller-cli app quality <preset> | panels [sidebar|log|text] | quit
```
