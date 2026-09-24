# Contributing

Issues and pull requests are welcome.

## Before you start

- Read [docs/spec.md](docs/spec.md). It is the source of truth for the protocol; code follows it,
  not the other way round. A protocol change starts as a spec change in the same pull request.
- Read the security rules in [README.md, section 9](README.md#9-security-rules). A change that
  breaks one of them will not be merged, however useful it is.
- For anything larger than a fix, open an issue first so the design can be agreed before the work.

## Building and testing

The commands are in [README.md, section 8](README.md#8-building-and-testing). Every suite you touch
must pass. If you change a schema or a key table, regenerate the vectors and code:

```sh
cd packages/protocol && npm run vectors && npm run codegen
```

and make sure the Swift and Kotlin vector tests still agree with them.

## Pull requests

- Keep each pull request to one change, with tests for it.
- Match the style of the code around it.
- Never commit real keys, pairing codes, addresses of your own machines, or logs from a session.

## Security issues

Do not report them in public issues or pull requests. See [SECURITY.md](SECURITY.md).

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
