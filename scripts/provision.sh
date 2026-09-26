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
Usage: provision.sh [-o ORG] <sprite-name>

  -o, --org ORG   Fly.io organization to create the Sprite in
  -h, --help      Show this help

Environment:
  SPRITE_FLAKE_DIR  Directory holding flake.nix (default: repo root, else $PWD)
  REMOTE_DIR        Where to place the flake in the guest
                    (default: /home/sprite/.config/home-manager)
EOF
}

sprite_name=""
org=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o | --org)
      [ $# -ge 2 ] || die "$1 needs a value"
      org="$2"
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
sprite file push "${sprite_flags[@]}" "$tmp/flake.tar.gz" /tmp/sprites-provision.tar.gz
sprite exec "${sprite_flags[@]}" -- sh -c "
  set -e
  mkdir -p '$REMOTE_DIR'
  tar -xzf /tmp/sprites-provision.tar.gz -C '$REMOTE_DIR'
  rm -f /tmp/sprites-provision.tar.gz
  chmod +x '$REMOTE_DIR/scripts/bootstrap-guest.sh'
"

log "bootstrapping Nix and activating home-manager (first run downloads a lot)"
sprite exec "${sprite_flags[@]}" --tty \
  --env "FLAKE_DIR=$REMOTE_DIR,HM_CONFIG=$config" \
  -- "$REMOTE_DIR/scripts/bootstrap-guest.sh"

log "verifying"
# shellcheck disable=SC2016  # expanded inside the guest, not here
sprite exec "${sprite_flags[@]}" -- bash -lc '
  printf "nix       %s\n" "$(nix --version 2>/dev/null || echo MISSING)"
  printf "git       %s\n" "$(git --version 2>/dev/null || echo MISSING)"
  printf "home-manager %s\n" "$(home-manager --version 2>/dev/null || echo MISSING)"
'

cat >&2 <<EOF

$(log "done")
  open a shell:      sprite console -s $sprite_name
  re-apply changes:  ./scripts/provision.sh $sprite_name
  snapshot it:       sprite checkpoint create -s $sprite_name
EOF
