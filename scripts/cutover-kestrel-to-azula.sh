#!/usr/bin/env bash
# shellcheck disable=SC2029 # Remote snippets intentionally interpolate audited local paths/heads.
# One-time custody transfer for the private Kestrel Familiar instance.
#
# Fort must be deployed first: it declares /var/lib/kestrel, credentials,
# baseline tools, and familiar-instance. This script transfers only the private
# checkout and ignored runtime state, then starts the declarative unit.
set -euo pipefail

source_repo="${KESTREL_SOURCE:-/home/dev/Projects/kestrel}"
target="${KESTREL_TARGET:-admin@azula.fort.gisi.network}"
target_dir="/var/lib/kestrel"
execute=0
source_stopped=0
copy_gh=1

usage() {
  cat <<'EOF'
Usage: cutover-kestrel-to-azula.sh [options]

Dry-runs by default. Execution requires both explicit custody assertions:
  --execute              perform the transfer
  --source-stopped       assert the old Familiar owner is fully stopped

Options:
  --source PATH          Kestrel checkout (default: /home/dev/Projects/kestrel)
  --target USER@HOST     SSH target (default: admin@azula.fort.gisi.network)
  --no-gh-credential     do not copy ~/.config/gh/hosts.yml
  -h, --help             show this help
EOF
}

while (($#)); do
  case "$1" in
    --source) source_repo=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    --source-stopped) source_stopped=1; shift ;;
    --no-gh-credential) copy_gh=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo_url="https://git.gisi.network/infra/kestrel.git"
cd "$source_repo"

echo "== local custody checks =="
test "$(git remote get-url origin)" = "$repo_url" || {
  echo "unexpected Kestrel origin: $(git remote get-url origin)" >&2
  exit 1
}
git fetch --quiet origin main
if test -n "$(git status --porcelain=v1)"; then
  echo "Kestrel checkout is not clean" >&2
  git status --short >&2
  exit 1
fi
local_head=$(git rev-parse HEAD)
remote_head=$(git rev-parse origin/main)
test "$local_head" = "$remote_head" || {
  echo "Kestrel HEAD is not exactly origin/main" >&2
  echo "local:  $local_head" >&2
  echo "remote: $remote_head" >&2
  exit 1
}
printf 'archive head: %s\n' "$local_head"

if ((copy_gh)) && ! test -f "$HOME/.config/gh/hosts.yml"; then
  echo "GitHub credential not found at ~/.config/gh/hosts.yml" >&2
  exit 1
fi

echo "== target declarative readiness =="
ssh "$target" "
  set -eu
  systemctl cat familiar-instance.service | grep -q '$target_dir/familiar.toml'
  systemctl is-enabled --quiet familiar-instance.service
  test \"\$(stat -c %U:%G '$target_dir')\" = familiar:users
  test \"\$(stat -c %a '$target_dir')\" = 700
  sudo test -s /var/lib/fort-git/familiar-token
  test -s /home/familiar/.ssh/id_ed25519
  test \"\$(stat -c %U:%G /home/familiar/.ssh/id_ed25519)\" = familiar:users
  test \"\$(stat -c %a /home/familiar/.ssh/id_ed25519)\" = 600
  command -v gh >/dev/null
  command -v rsync >/dev/null
"

cat <<EOF

Ready to transfer:
  source:       $source_repo
  destination:  $target:$target_dir
  archive head: $local_head
  ignored state:
    state/pi/
    state/age.key
    state/voices/
    state/herdr/
    state/worklist/
  GitHub auth:  $([[ $copy_gh = 1 ]] && echo copy || echo skip)

The old owner must be fully stopped before execution. The script stops the
Azula unit, but cannot prove that the source-side Presence/Pi process is dead.
EOF

if ((!execute)); then
  echo
  echo "DRY RUN complete. Re-run with --execute --source-stopped."
  exit 0
fi
if ((!source_stopped)); then
  echo "refusing execution without --source-stopped" >&2
  exit 1
fi

echo "== stop destination owner =="
ssh "$target" 'sudo systemctl stop familiar-instance.service || true'

echo "== provision exact tracked archive =="
ssh "$target" "
  set -euo pipefail
  sudo -u familiar -H git -C '$target_dir' init -q
  if sudo -u familiar -H git -C '$target_dir' remote get-url origin >/dev/null 2>&1; then
    test \"\$(sudo -u familiar -H git -C '$target_dir' remote get-url origin)\" = '$repo_url'
  else
    sudo -u familiar -H git -C '$target_dir' remote add origin '$repo_url'
  fi
  sudo -u familiar -H git -C '$target_dir' fetch --quiet --prune origin main
  sudo -u familiar -H git -C '$target_dir' checkout -q -B main origin/main
  test \"\$(sudo -u familiar -H git -C '$target_dir' rev-parse HEAD)\" = '$local_head'
"

echo "== transfer ignored live state =="
# rsync runs under sudo remotely because /var/lib/kestrel is service-owned.
for relative in state/pi state/voices state/herdr state/worklist; do
  if test -d "$source_repo/$relative"; then
    ssh "$target" "sudo install -d -o familiar -g users -m 0700 '$target_dir/$relative'"
    rsync -a --delete --rsync-path='sudo rsync' \
      "$source_repo/$relative/" "$target:$target_dir/$relative/"
  fi
done
rsync -a --rsync-path='sudo rsync' \
  "$source_repo/state/age.key" "$target:$target_dir/state/age.key"

if ((copy_gh)); then
  echo "== install GitHub CLI credential =="
  rsync -a --rsync-path='sudo rsync' \
    "$HOME/.config/gh/hosts.yml" "$target:/home/familiar/.config/gh/hosts.yml"
fi

echo "== tighten ownership and credential modes =="
ssh "$target" "
  set -euo pipefail
  sudo chown -R familiar:users '$target_dir'
  sudo chmod 0700 '$target_dir'
  sudo chmod 0600 '$target_dir/familiar.toml' '$target_dir/state/age.key'
  test ! -e '$target_dir/state/pi/auth.json' || sudo chmod 0600 '$target_dir/state/pi/auth.json'
  if test $copy_gh -eq 1; then
    sudo chown familiar:users /home/familiar/.config/gh/hosts.yml
    sudo chmod 0600 /home/familiar/.config/gh/hosts.yml
  fi
"

echo "== start the sole owner =="
ssh "$target" 'sudo systemctl start familiar-instance.service'

echo "== verify custody and capability =="
ssh "$target" "
  set -euo pipefail
  test \"\$(sudo -u familiar -H git -C '$target_dir' rev-parse HEAD)\" = '$local_head'
  test -z \"\$(sudo -u familiar -H git -C '$target_dir' status --porcelain=v1)\"
  test -n \"\$(find '$target_dir/state/pi/sessions' -type f -name '*.jsonl' -print -quit)\"
  sudo -u familiar -H git -C '$target_dir' ls-remote origin HEAD >/dev/null
  if test $copy_gh -eq 1; then sudo -u familiar -H gh auth status >/dev/null; fi
  systemctl is-active --quiet familiar-instance.service
  for i in \$(seq 1 30); do
    if curl -fsS http://127.0.0.1:1692/ >/dev/null 2>&1; then exit 0; fi
    sleep 1
  done
  echo 'Familiar did not become healthy within 30 seconds' >&2
  systemctl status --no-pager familiar-instance.service >&2
  exit 1
"

echo
printf 'KESTREL_CUTOVER_OK head=%s target=%s\n' "$local_head" "$target"
