#!/usr/bin/env bash
#
# Provision a Fly.io Sprite with Nix and standalone home-manager.
#
# Runs on your machine and drives the `sprite` CLI: creates the Sprite if it
# does not exist, ships this flake into it, then runs scripts/bootstrap-guest.sh
# inside the guest to install Nix and activate the home configuration.
#
# Usage: ./scripts/provision.sh [-o ORG] <sprite-name>
#
set -euo pipefail

REMOTE_DIR=${REMOTE_DIR:-/home/sprite/.config/home-manager}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: provision.sh [-o ORG] [options] <sprite-name>

  -o, --org ORG          Fly.io organization to create the Sprite in
      --ts-authkey-file F  Read the Tailscale auth key from file F
      --ts-hostname NAME Tailnet hostname (default: the sprite name)
      --ts-tags TAGS     Advertise tags, ';'-separated: 'tag:a;tag:b'
      --no-ts-ssh        Do not enable Tailscale SSH on the node
      --no-tailscale     Skip Tailscale entirely
      --no-hermes        Do not define the `hermes serve` service
      --hermes-env FILE  Install FILE as the guest's ~/.hermes/.env (mode 600)
  -h, --help             Show this help

Environment:
  TS_AUTHKEY        Tailscale auth key. Preferred over a flag so the key never
                    lands in your shell history or in `ps` output, e.g.
                      TS_AUTHKEY=$(security find-generic-password -w -s ts-authkey) \
                        ./scripts/provision.sh mysprite
                    Use an ephemeral, pre-approved, reusable-disabled key: it
                    is needed exactly once. After `tailscale up` the node
                    identity lives in /var/lib/tailscale on the guest's
                    persistent disk, so re-provisioning needs no key at all.
  SPRITE_FLAKE_DIR  Directory holding flake.nix (default: repo root, else $PWD)
  REMOTE_DIR        Where to place the flake in the guest
                    (default: /home/sprite/.config/home-manager)
EOF
}

sprite_name=""
org=""
ts_authkey=${TS_AUTHKEY:-}
ts_hostname=""
ts_tags=""
ts_ssh=1
enable_tailscale=1
enable_hermes=1
hermes_env_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o | --org)
      [ $# -ge 2 ] || die "$1 needs a value"
      org="$2"
      shift 2
      ;;
    --ts-authkey-file)
      [ $# -ge 2 ] || die "$1 needs a value"
      [ -f "$2" ] || die "no such file: $2"
      ts_authkey=$(tr -d '\r\n' <"$2")
      shift 2
      ;;
    --ts-hostname)
      [ $# -ge 2 ] || die "$1 needs a value"
      ts_hostname="$2"
      shift 2
      ;;
    --ts-tags)
      [ $# -ge 2 ] || die "$1 needs a value"
      ts_tags="$2"
      shift 2
      ;;
    --no-ts-ssh)
      ts_ssh=0
      shift
      ;;
    --no-tailscale)
      enable_tailscale=0
      shift
      ;;
    --no-hermes)
      enable_hermes=0
      shift
      ;;
    --hermes-env)
      [ $# -ge 2 ] || die "$1 needs a value"
      [ -f "$2" ] || die "no such file: $2"
      hermes_env_file="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      ;;
    -*)
      usage
      die "unknown flag: $1"
      ;;
    *)
      [ -z "$sprite_name" ] || die "only one sprite name may be given"
      sprite_name="$1"
      shift
      ;;
  esac
done

# `sprite exec --env` is a comma-separated list, so a comma inside a value
# would silently split into a bogus variable. Tags are the one option that
# naturally contains commas; take them ';'-separated and let the guest
# translate. Anything else containing a comma is rejected rather than mangled.
case "$ts_tags" in
  *,*) die "--ts-tags must be ';'-separated, not ',' (e.g. 'tag:a;tag:b')" ;;
esac
case "$ts_hostname" in
  *,*) die "--ts-hostname must not contain a comma" ;;
esac

[ -n "$sprite_name" ] || {
  usage
  die "sprite name is required"
}

command -v sprite >/dev/null 2>&1 ||
  die "the 'sprite' CLI is not on PATH — try 'nix develop' or 'nix run .#provision'"

# Locate the flake. When this script runs from the Nix store (nix run
# .#provision) the path next to the script is not the repo, so fall back to
# the working directory.
flake_dir=${SPRITE_FLAKE_DIR:-}
if [ -z "$flake_dir" ]; then
  script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  if [ -f "$script_dir/flake.nix" ]; then
    flake_dir=$script_dir
  elif [ -f "$PWD/flake.nix" ]; then
    flake_dir=$PWD
  else
    die "cannot find flake.nix — run from the repo root or set SPRITE_FLAKE_DIR"
  fi
fi
[ -f "$flake_dir/flake.nix" ] || die "no flake.nix in $flake_dir"
[ -f "$flake_dir/scripts/bootstrap-guest.sh" ] ||
  die "no scripts/bootstrap-guest.sh in $flake_dir"

if [ ! -f "$flake_dir/flake.lock" ]; then
  log "no flake.lock, generating one"
  nix flake lock "$flake_dir"
fi

# Keep the org flag out of an array until it is known to be non-empty: macOS
# ships bash 3.2, where expanding an empty array under `set -u` is an error.
sprite_flags=(-s "$sprite_name")
if [ -n "$org" ]; then
  sprite_flags=(--org "$org" "${sprite_flags[@]}")
fi

# `sprite exec -- true` is the cheapest existence + auth probe that does not
# depend on parsing `sprite list` output.
if ! sprite exec "${sprite_flags[@]}" -- true >/dev/null 2>&1; then
  log "sprite '$sprite_name' not reachable, creating it"
  if [ -n "$org" ]; then
    sprite create --org "$org" --skip-console "$sprite_name"
  else
    sprite create --skip-console "$sprite_name"
  fi ||
    die "could not create sprite '$sprite_name' (authenticated? try 'sprite login')"
  sprite exec "${sprite_flags[@]}" -- true >/dev/null ||
    die "sprite '$sprite_name' created but not reachable"
fi

guest_arch=$(sprite exec "${sprite_flags[@]}" -- uname -m | tr -d '\r' | tail -n 1)
case "$guest_arch" in
  x86_64 | amd64) config=sprite ;;
  aarch64 | arm64) config=sprite-aarch64 ;;
  *) die "unsupported guest architecture: $guest_arch" ;;
esac
log "guest is $guest_arch, using homeConfigurations.$config"

tmp=$(mktemp -d)
# shellcheck disable=SC2064  # expand $tmp now, not at trap time
trap "rm -rf '$tmp'" EXIT

log "packing flake from $flake_dir"
tar -czf "$tmp/flake.tar.gz" -C "$flake_dir" \
  --exclude .git --exclude result --exclude 'result-*' \
  flake.nix flake.lock home scripts

log "pushing flake to $REMOTE_DIR"
# -p is not optional: `sprite file push` (rc48) pre-flight-checks the remote
# parent directory and wrongly reports "directory /tmp does not exist" for
# paths outside $HOME. -p skips that check; the write itself is fine.
sprite file push "${sprite_flags[@]}" -p "$tmp/flake.tar.gz" /tmp/sprites-provision.tar.gz
sprite exec "${sprite_flags[@]}" -- sh -c "
  set -e
  mkdir -p '$REMOTE_DIR'
  tar -xzf /tmp/sprites-provision.tar.gz -C '$REMOTE_DIR'
  rm -f /tmp/sprites-provision.tar.gz
  chmod +x '$REMOTE_DIR/scripts/bootstrap-guest.sh'
"

log "bootstrapping Nix and activating home-manager (first run downloads a lot)"

# Secrets travel as files, never as `--env` values or argv: `sprite exec --env`
# puts a value in the guest process environment (readable through /proc for the
# lifetime of that process) and a flag value shows up in `ps` on both ends. A
# pushed file can be mode 600 and deleted by the consumer.
guest_env="FLAKE_DIR=$REMOTE_DIR,HM_CONFIG=$config"
guest_env="$guest_env,ENABLE_TAILSCALE=$enable_tailscale,ENABLE_HERMES=$enable_hermes"
guest_env="$guest_env,TS_SSH=$ts_ssh"
guest_env="$guest_env,TS_HOSTNAME=${ts_hostname:-$sprite_name}"

if [ -n "$ts_tags" ]; then
  # Commas are the --env separator, so tags arrive ';'-separated and the guest
  # translates them back.
  guest_env="$guest_env,TS_TAGS=$ts_tags"
fi

if [ "$enable_tailscale" = 1 ] && [ -n "$ts_authkey" ]; then
  log "pushing the Tailscale auth key (mode 600, deleted by the guest after use)"
  (
    umask 077
    printf '%s' "$ts_authkey" >"$tmp/ts-authkey"
  )
  # `sprite file push` pre-flight-checks the destination's parent, so create it
  # first; ~/.cache is on the persistent disk but the guest shreds the file the
  # moment it has been consumed.
  # shellcheck disable=SC2016  # $HOME must expand in the guest, not here
  sprite exec "${sprite_flags[@]}" -- sh -c 'mkdir -p "$HOME/.cache"'
  sprite file push "${sprite_flags[@]}" -p "$tmp/ts-authkey" /home/sprite/.cache/ts-authkey
  sprite exec "${sprite_flags[@]}" -- chmod 600 /home/sprite/.cache/ts-authkey
  guest_env="$guest_env,TS_AUTHKEY_FILE=/home/sprite/.cache/ts-authkey"
  unset ts_authkey
fi

if [ -n "$hermes_env_file" ]; then
  log "installing ~/.hermes/.env in the guest (mode 600)"
  # shellcheck disable=SC2016  # $HOME must expand in the guest, not here
  sprite exec "${sprite_flags[@]}" -- sh -c 'mkdir -p "$HOME/.hermes"'
  sprite file push "${sprite_flags[@]}" -p "$hermes_env_file" /home/sprite/.hermes/.env
  sprite exec "${sprite_flags[@]}" -- chmod 600 /home/sprite/.hermes/.env
fi

# Deliberately no --tty. Two reasons:
#   1. With stderr on a guest PTY, nix stops to ask about this flake's
#      nixConfig even when passed --no-accept-flake-config, so the run hangs.
#      Without a TTY it warns, ignores the setting and continues.
#   2. TTY sessions are detachable, so a cancelled run leaves the bootstrap
#      alive inside the sprite and the next run fights it. Check for leftovers
#      with `sprite sessions list -s <name>`.
sprite exec "${sprite_flags[@]}" \
  --env "$guest_env" \
  -- "$REMOTE_DIR/scripts/bootstrap-guest.sh"

# Verify in a *login* bash and in fish, because they load the environment by
# different routes, and fail the run if either is missing the nix profile — an
# earlier version printed MISSING and still exited 0, reporting a broken
# provision as success.
log "verifying login shell (bash -l)"
# shellcheck disable=SC2016  # expanded inside the guest, not here
sprite exec "${sprite_flags[@]}" -- bash -lc '
  fail=0
  for t in nix home-manager git go hermes claude crush; do
    p=$(command -v "$t" 2>/dev/null) || p=""
    case "$p" in
      "$HOME"/.nix-profile/bin/*) printf "  %-13s %s\n" "$t" "$p" ;;
      "") printf "  %-13s MISSING\n" "$t"; fail=1 ;;
      *) printf "  %-13s %s  (not the nix-managed one)\n" "$t" "$p"; fail=1 ;;
    esac
  done
  exit "$fail"
' || die "the login shell is missing nix-managed tools (see above)"

if sprite exec "${sprite_flags[@]}" -- sh -c 'command -v fish >/dev/null 2>&1'; then
  log "verifying fish"
  # shellcheck disable=SC2016  # expanded inside the guest, not here
  sprite exec "${sprite_flags[@]}" -- fish -lc '
    set fail 0
    for t in nix home-manager hermes claude
      if command -q $t
        printf "  %-13s %s\n" $t (command -v $t)
      else
        printf "  %-13s MISSING\n" $t
        set fail 1
      end
    end
    exit $fail
  ' || die "fish does not have the nix environment loaded"
fi

ts_backend=""
if [ "$enable_tailscale" = 1 ]; then
  log "verifying the tailnet node"
  # shellcheck disable=SC2016  # expanded inside the guest, not here
  ts_report=$(sprite exec "${sprite_flags[@]}" -- bash -lc '
    sock=/var/run/tailscale/tailscaled.sock
    # Absolute path, not a bare name: sudo resets PATH to secure_path, which
    # does not include the nix profile, so `sudo tailscale` is "command not
    # found" and the whole check silently reports "unreachable".
    sudo -n "$HOME/.nix-profile/bin/tailscale" --socket="$sock" status --json 2>/dev/null |
      jq -r "[(.BackendState // \"Unknown\"), (.Self.DNSName // \"-\"), ((.TailscaleIPs // [\"-\"])[0])] | @tsv"
  ' 2>/dev/null | tail -n 1) || ts_report=""

  ts_backend=$(printf '%s' "$ts_report" | cut -f1)
  ts_dnsname=$(printf '%s' "$ts_report" | cut -f2 | sed 's/\.$//')
  ts_addr=$(printf '%s' "$ts_report" | cut -f3)

  if [ "$ts_backend" = "Running" ]; then
    log "tailnet: $ts_dnsname ($ts_addr)"
  else
    log "WARNING: tailscale BackendState=${ts_backend:-unreachable} — the node is not on the tailnet"
  fi
fi

cat >&2 <<EOF

$(log "done")
  open a shell:      sprite console -s $sprite_name
  re-apply changes:  ./scripts/provision.sh $sprite_name
  snapshot it:       sprite checkpoint create -s $sprite_name
EOF

if [ "$enable_tailscale" = 1 ] && [ "$ts_backend" = "Running" ]; then
  cat >&2 <<EOF

  over the tailnet:
    ssh sprite@$ts_dnsname                      # Tailscale SSH, no sshd needed
EOF
  if [ "$enable_hermes" = 1 ]; then
    cat >&2 <<EOF
    ssh -N -L 9119:localhost:9119 sprite@$ts_dnsname   # then point the desktop app at localhost:9119

  hermes serve is bound to the guest's loopback on purpose: it trusts a
  loopback peer and skips authentication, so it is reached through the
  forward above rather than exposed on the tailnet or the Sprite URL.
EOF
  fi
fi
