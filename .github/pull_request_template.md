## What this changes

<!-- One change per pull request. What does it do, and why? Link the issue if there is one. -->

## How it was tested

<!-- Which suites you ran, from README section 8. Tick what applies. -->

- [ ] The automatic tests pass on this pull request
- [ ] `scripts/test-ios-simulator.sh`, if the iPhone app changed
- [ ] `scripts/test-android-device.sh` on a phone, if the Android app's pairing, session or terminal changed
- [ ] Tried on real devices: <!-- which, and what you did -->

## Checklist

- [ ] A protocol change starts with the spec (`docs/spec.md`), in this pull request, and the vectors and generated code are regenerated
- [ ] Nothing here breaks a security rule (README section 9, spec section 24): no command message, no granting command on the local control channel, no key installed without a click on the Mac
- [ ] No personal data in the diff or the commit messages: no real keys, pairing codes, fingerprints, addresses of your own machines, session logs, Apple team ID or bundle identifier of your own
- [ ] Docs updated where behaviour changed (README, `docs/implementation.md`, an app's README)
