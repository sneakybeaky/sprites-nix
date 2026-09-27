# Test harness

## `sprite-stub`

A stub `sprite` CLI for dry-running `scripts/provision.sh` without touching
Fly.io. It logs every invocation, answers the probes (`-- true`, `-- uname -m`),
copies on `file push`, and runs remote `sh -c` snippets locally against a
temporary guest root.

```bash
rm -rf /tmp/dryrun && mkdir -p /tmp/dryrun/remote
export STUB_LOG=/tmp/dryrun/log REMOTE_ROOT=/tmp/dryrun/remote
PATH="$PWD/tests:$PATH" /bin/bash scripts/provision.sh --org myorg dry-sprite
cat /tmp/dryrun/log
```

Run it with `/bin/bash` (macOS bash 3.2), not the Nix bash: an empty array
expansion under `set -u` is an error there and nowhere else, and that is
exactly the class of bug this catches.

Assert on the log: the expected call sequence, `--org` present on every call
when passed (and absent when not), the shipped tree containing `flake.nix`,
`flake.lock`, `home/` and `scripts/`, and the auth key arriving as a mode-600
file rather than an `--env` value or an argv flag.

Two remaps make the local run work, and are stub concerns rather than product
behaviour: guest absolute paths (`/home/sprite`, `/tmp/sprites-provision*`) are
rewritten into `$REMOTE_ROOT`.
