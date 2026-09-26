# sprites-provision

Provision [Fly.io Sprites](https://docs.sprites.dev/) with Nix and standalone
[home-manager](https://github.com/nix-community/home-manager).

A Sprite is a persistent Firecracker microVM running an Ubuntu base image: the
filesystem survives hibernation, RAM does not. That makes it a good fit for a
declarative home: install Nix once, and every later change is a `nix build` plus
an activation switch.

## Layout

| Path                        | Runs where | Purpose                                                        |
| --------------------------- | ---------- | -------------------------------------------------------------- |
| `flake.nix`                 | both       | `pkgs.sprite` CLI, dev shell, guest home configurations        |
| `home/sprite.nix`           | guest      | The home-manager module applied inside the Sprite              |
| `scripts/provision.sh`      | host       | Drives the `sprite` CLI: create, ship this flake, bootstrap    |
| `scripts/bootstrap-guest.sh`| guest      | Installs single-user Nix, builds and activates the home config |

## Usage

```sh
direnv allow           # or: nix develop
nix develop            # sprite CLI + home-manager + shellcheck on PATH
sprite login           # once
./scripts/provision.sh my-sprite
sprite console -s my-sprite
```

Or without cloning a dev shell:

```sh
nix run github:you/sprites-provision#provision -- my-sprite
```

Re-run `provision.sh` after editing `home/sprite.nix` to apply changes; it is
idempotent and only rebuilds what changed.

## Design notes

- **The `sprite` CLI comes from nixpkgs** (`pkgs/by-name/sp/sprite`), not a
  vendored derivation. Upstream ships the `UPGRADE_CHECK=false` wrapper and a
  `versionCheckHook`, and it gets version bumps for free. It is unfree
  (redistributed prebuilt binary), so the flake sets an
  `allowUnfreePredicate` scoped to that single package rather than enabling
  unfree globally.
- **`nixpkgs-unstable` is required for `sprite`.** It was added to nixpkgs in
  February 2026, after the 25.11 branch point, so 25.11 has no `pkgs.sprite`
  at all.
- **No `x86_64-darwin`.** nixpkgs 26.11 dropped the platform outright, and
  upstream `sprite` has no hash for it. Intel macs need a `nixos-26.05` pin.
- **Single-user Nix in the guest** (`--no-daemon`): there is no systemd to run
  `nix-daemon` under, and a hibernating Sprite loses any resident process
  while keeping its disk.
- **Builds in the guest are not sandboxed**, and cannot be: Nix's sandbox needs
  a daemon running as root. Every `nix build` therefore runs its build scripts
  as `sprite` with full access to the home directory, which matters if agents in
  the Sprite evaluate flakes you have not read. `accept-flake-config = false`
  plus `--no-accept-flake-config` at least stops a fetched flake from injecting
  substituters or trusted keys. Unprivileged user namespaces *are* available in
  the guest, so a multi-user install (`nix-installer --init none`, daemon
  registered as a `sprite-env` service) is the route to real sandboxing if you
  need it.
- **Nix config is not managed by home-manager.** `home.packages` installs into
  the same `~/.nix-profile` that the installer uses for `nix` itself, so
  setting `nix.package` there makes activation fail on `bin/nix`.
  `bootstrap-guest.sh` owns `~/.config/nix/nix.conf` instead.
- **No systemd units.** Use `sprite-env services create` inside the guest for
  anything long-running; it restarts on wake, systemd user services do not
  exist.
- **`.bashrc` sources `hm-session-vars.sh` explicitly**, because
  `sprite console` starts an interactive non-login shell that never reads
  `~/.profile`.
- **Agent CLIs come from [`numtide/llm-agents.nix`](https://github.com/numtide/llm-agents.nix)**
  (`hermes-agent`, `claude-code`), exposed as `pkgs.llm-agents` by an overlay —
  upstream dropped its own overlay output, so the namespace is built from its
  per-system `packages`. That input deliberately does **not** follow our
  nixpkgs: its prebuilt closures are keyed to its own pin. They are cached
  only by `cache.numtide.com`, so `bootstrap-guest.sh` writes that substituter
  into the guest's `nix.conf` — without it the microVM compiles both from
  source.
