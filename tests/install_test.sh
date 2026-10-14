#!/usr/bin/env bash
#
# Tests for install.sh's shell-file handling and the caveman readiness check.
# Each case runs against a throwaway $HOME, so the real one is never touched.
#
#   ./tests/install_test.sh
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# Never let a test fall through to the real ~/.claude.
unset CLAUDE_CONFIG_DIR

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
not()   { ! "$@"; }

# Fresh $HOME with a copy of the repo at ~/dotfiles, so ~/… paths are testable.
new_home() {
  H="$SCRATCH/home$((++N))"
  D="$H/dotfiles"
  mkdir -p "$D"
  cp -r "$REPO/install.sh" "$REPO/claude" "$REPO/shell" "$D/"
}
N=0

# Debian-style bashrc: mentions .bash_aliases in a comment AND really loads it.
debian_bashrc() {
  cat > "$H/.bashrc" <<'EOF'
# ~/.bash_aliases, instead of adding them here directly.
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
}

install() { HOME="$H" "$D/install.sh" "$@" 2>&1; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }

echo "install.sh"

new_home; debian_bashrc
out="$(install)"
check "fresh install sources aliases from ~/.bash_aliases" \
  grep -Fqx "[ -f \"$D/shell/bash_aliases\" ] && . \"$D/shell/bash_aliases\"" "$H/.bash_aliases"
check "fresh install sources caveman.env from ~/.bashrc" \
  grep -Fqx "[ -f \"$D/claude/local/caveman.env\" ] && . \"$D/claude/local/caveman.env\"" "$H/.bashrc"
check "no load-aliases note when ~/.bashrc really loads them" \
  not grep -q "doesn't load" <<<"$out"

before="$(cat "$H/.bashrc" "$H/.bash_aliases")"
install >/dev/null
check "re-running is a no-op" \
  test "$before" = "$(cat "$H/.bashrc" "$H/.bash_aliases")"

new_home
printf '# put aliases in ~/.bash_aliases\n' > "$H/.bashrc"
out="$(install)"
check "note shown when ~/.bash_aliases is only mentioned in a comment" \
  grep -q "doesn't load ~/.bash_aliases" <<<"$out"

new_home; debian_bashrc
printf '\nsource ~/dotfiles/claude/local/caveman.env\n' >> "$H/.bashrc"
install >/dev/null
check "hand-added ~/… caveman line is not duplicated" \
  test "$(count caveman.env "$H/.bashrc")" -eq 1

new_home; debian_bashrc
install >/dev/null
mv "$D" "$H/moved"
err="$(HOME="$H" bash -c '. ~/.bash_aliases; . ~/.bashrc' 2>&1 >/dev/null)"
check "moved repo: stale lines stay silent" test -z "$err"

new_home; debian_bashrc
before="$(cat "$H/.bashrc")"
install --dry-run >/dev/null
check "dry run leaves ~/.bashrc unchanged" test "$before" = "$(cat "$H/.bashrc")"
check "dry run creates no ~/.bash_aliases" test ! -e "$H/.bash_aliases"

echo "caveman --check / caveman.env"

# Fake caveman install: proxy binary, plus an npm-style `caveman` symlink into
# <pkg>/dist/ with the hook adapter beside it. Pieces are removed per case.
fake_caveman() {
  mkdir -p "$H/.caveman/bin" "$H/pkg/dist" "$H/bin"
  printf '#!/bin/sh\n' > "$H/.caveman/bin/caveman-proxy"
  chmod +x "$H/.caveman/bin/caveman-proxy"
  printf '#!/bin/sh\n' > "$H/pkg/dist/index.js"
  chmod +x "$H/pkg/dist/index.js"
  touch "$H/pkg/dist/native-hook-fast.js"
  ln -s "$H/pkg/dist/index.js" "$H/bin/caveman"
}
# Minimal PATH so a real caveman on this machine can't leak into the test.
in_fake() { HOME="$H" PATH="$H/bin:/usr/bin:/bin" "$@"; }
check_ok() { in_fake "$D/claude/hooks/caveman" --check; }
env_url() { in_fake bash -c 'unset ANTHROPIC_BASE_URL; . "$1"; echo "${ANTHROPIC_BASE_URL:-}"' _ "$D/claude/local/caveman.env"; }
hook_exit() { in_fake "$D/claude/hooks/caveman" </dev/null; echo $?; }

new_home; fake_caveman
check "fully installed: --check passes" check_ok
check "fully installed: caveman.env sets the proxy URL" \
  test "$(env_url)" = "http://127.0.0.1:8787/w/claude"

for missing in proxy cli adapter; do
  new_home; fake_caveman
  case "$missing" in
    proxy)   rm "$H/.caveman/bin/caveman-proxy" ;;
    cli)     rm "$H/bin/caveman" ;;
    adapter) rm "$H/pkg/dist/native-hook-fast.js" ;;
  esac
  check "no $missing: --check fails" not check_ok
  check "no $missing: caveman.env leaves the API direct" test -z "$(env_url)"
  check "no $missing: hook still exits 0 (inert)" test "$(hook_exit)" = 0
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
