# Security policy

PRC takes a Mac's screen and injects its keyboard and mouse. A flaw here can hand someone else
control of a machine, so security reports come first.

## Reporting a vulnerability

Do not open a public issue. Report it privately through GitHub:
**Security → Report a vulnerability** on this repository.

Include what you can of:

- what an attacker can do, and from where (same network, tailnet, relay, a paired device);
- the steps or a proof of concept;
- the versions or commit you tested.

You will get an acknowledgement within a week. A fix is prepared in a private advisory and
published together with the advisory once released, crediting you unless you prefer otherwise.

## Scope

In scope: anything that lets an unpaired or revoked device pair, connect, resume, read the screen,
or inject input; bypasses of host approval; signature or envelope validation flaws; leaks of
private keys or pairing codes; any path to run a command or touch files on the host.

Out of scope: attacks that need an already-compromised host or controller, or physical access to
an unlocked one; weaknesses in Tailscale, WebRTC or the operating system themselves (report those
upstream).

## Supported versions

Only the latest commit on `main` receives fixes.

## Design

The threat model is in [docs/spec.md](docs/spec.md), section 23, and the rules every change must
follow are in section 24.
