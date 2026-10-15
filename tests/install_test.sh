#!/usr/bin/env bash
#
# Tests for install.sh (shell files, tool installs) and the caveman readiness
# check. Each case runs against a throwaway $HOME and a sandbox PATH where
# npm, git and bun are fakes, so nothing real is installed or downloaded.
#
#   ./tests/install_test.sh
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# Never let a test fall through to the real ~/.claude, or real git config.
unset CLAUDE_CONFIG_DIR XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
# Real binaries for checking results; install.sh itself only ever sees fakes.
REAL_GIT="$(command -v git || true)"
ZSH_BIN="$(command -v zsh || true)"

PIN_CAVEMAN="$(sed -n 's/^CAVEMAN_VERSION="\(.*\)"/\1/p' "$REPO/install.sh")"
PIN_GSTACK="$(sed -n 's/^GSTACK_REF="\([^"]*\)".*/\1/p' "$REPO/install.sh")"

# System tools minus the ones under test, so a real git/npm/caveman can't leak in.
SYSBIN="$SCRATCH/sysbin"
mkdir -p "$SYSBIN"
for f in /usr/bin/* /bin/*; do
  n="${f##*/}"
  case "$n" in git|npm|npx|node|bun|caveman) continue ;; esac
  [ -x "$f" ] && [ ! -e "$SYSBIN/$n" ] && ln -s "$f" "$SYSBIN/$n"
done

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
  cp -r "$REPO/install.sh" "$REPO/claude" "$REPO/shell" "$REPO/git" "$D/"
  SH=/bin/bash  # login shell install.sh sees; a case sets SH=/bin/zsh to switch
  fake_tools
}
N=0

# Fake npm/git/bun in ~/bin. Each logs its calls to ~/calls. Touch ~/npm-fails or
# ~/setup-fails to make that step fail. Like the real installers, the fakes edit
# ~/.claude/settings.json: caveman writes through the symlink, gstack's setup
# replaces the file atomically (which turns the symlink into a real file).
fake_tools() {
  mkdir -p "$H/bin"
  cat > "$H/bin/npm" <<'FAKE'
#!/bin/bash
echo "npm $*" >> "$HOME/calls"
[ -e "$HOME/npm-fails" ] && exit 1
args="$*"; echo "${args##*@}" > "$HOME/.fake-caveman-version"
cat > "$HOME/bin/caveman" <<'CAVE'
#!/bin/bash
echo "caveman $*" >> "$HOME/calls"
case "$1" in
  version) printf '{\n  "version": "%s"\n}\n' "$(cat "$HOME/.fake-caveman-version")" ;;
  setup)
    mkdir -p "$HOME/.caveman/bin"
    printf '#!/bin/sh\n' > "$HOME/.caveman/bin/caveman-proxy"
    chmod +x "$HOME/.caveman/bin/caveman-proxy"
    f="$HOME/.claude/settings.json"
    [ -e "$f" ] && { c="$(cat "$f")"; printf '%s\n"ANTHROPIC_BASE_URL from caveman"\n' "$c" > "$f"; } ;;
esac
CAVE
chmod +x "$HOME/bin/caveman"
FAKE
  cat > "$H/bin/git" <<'FAKE'
#!/bin/bash
echo "git $*" >> "$HOME/calls"
if [ "$1" = clone ]; then
  dir="${@: -1}"; mkdir -p "$dir"
  cat > "$dir/setup" <<'SETUP'
#!/bin/bash
echo "gstack-setup in $PWD" >> "$HOME/calls"
[ -e "$HOME/setup-fails" ] && exit 1
f="$HOME/.claude/settings.json"
{ cat "$f"; echo '"hook from gstack"'; } > "$f.tmp" && mv "$f.tmp" "$f"
SETUP
  chmod +x "$dir/setup"
elif [ "$1" = -C ]; then
  case "$3" in
    reset)     echo "${@: -1}" > "$2/.ref" ;;
    rev-parse) cat "$2/.ref" ;;
  esac
fi
FAKE
  printf '#!/bin/sh\n' > "$H/bin/bun"
  chmod +x "$H/bin/npm" "$H/bin/git" "$H/bin/bun"
}

# Debian-style bashrc: mentions .bash_aliases in a comment AND really loads it.
debian_bashrc() {
  cat > "$H/.bashrc" <<'EOF'
# ~/.bash_aliases, instead of adding them here directly.
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
}

install() { HOME="$H" SHELL="$SH" PATH="$H/bin:$SYSBIN" "$D/install.sh" "$@" 2>&1; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }
# settings.json still a symlink to the repo copy, with the repo copy unchanged.
settings_intact() {
  [ "$(readlink -f "$H/.claude/settings.json")" = "$(readlink -f "$D/claude/settings.json")" ] \
    && cmp -s "$D/claude/settings.json" "$REPO/claude/settings.json"
}

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

new_home; SH=/bin/zsh
out="$(install)"
check "zsh: aliases sourced from ~/.zshrc" \
  grep -Fqx "[ -f \"$D/shell/bash_aliases\" ] && . \"$D/shell/bash_aliases\"" "$H/.zshrc"
check "zsh: caveman.env sourced from ~/.zshrc" \
  grep -Fqx "[ -f \"$D/claude/local/caveman.env\" ] && . \"$D/claude/local/caveman.env\"" "$H/.zshrc"
check "zsh: bash files left alone" not test -e "$H/.bashrc" -o -e "$H/.bash_aliases"
check "zsh: no ~/.bashrc note" not grep -q "doesn't load" <<<"$out"
before="$(cat "$H/.zshrc")"
install >/dev/null
check "zsh: re-running is a no-op" test "$before" = "$(cat "$H/.zshrc")"

echo "tools"

new_home; debian_bashrc
out="$(install)"; rc=$?
check "fresh: exits 0" test "$rc" -eq 0
check "fresh: installs the pinned caveman CLI" \
  grep -Fqx "npm install -g @caveman-ai/cli@$PIN_CAVEMAN" "$H/calls"
check "fresh: runs caveman setup --install" grep -Fqx "caveman setup --install" "$H/calls"
check "fresh: clones gstack's main branch" \
  grep -Fq -- "--branch main https://github.com/garrytan/gstack.git $H/.claude/skills/gstack" "$H/calls"
check "fresh: resets gstack to the pinned commit" \
  grep -Fqx "git -C $H/.claude/skills/gstack reset -q --hard $PIN_GSTACK" "$H/calls"
check "fresh: runs gstack setup from inside its dir" \
  grep -Fqx "gstack-setup in $H/.claude/skills/gstack" "$H/calls"
check "fresh: installers' settings.json edits are reverted" settings_intact
check "fresh: the reverted edits are shown" grep -q '+"hook from gstack"' <<<"$out"

rm "$H/calls"
out="$(install)"
check "re-run: installs nothing again" \
  not grep -q -e '^npm' -e 'clone' -e 'reset' -e 'setup' "$H/calls"
check "re-run: reports both as ok at the pin" \
  bash -c 'grep -q "ok:   caveman $1" <<<"$3" && grep -q "ok:   gstack ${2:0:7}" <<<"$3"' _ "$PIN_CAVEMAN" "$PIN_GSTACK" "$out"

new_home; debian_bashrc
echo 9.9.9 > "$H/.fake-caveman-version"
HOME="$H" PATH="$H/bin:$SYSBIN" bash -c 'npm install -g @caveman-ai/cli@9.9.9 >/dev/null; caveman setup >/dev/null'
mkdir -p "$H/.claude/skills/gstack" && echo 1234567deadbeef > "$H/.claude/skills/gstack/.ref"
rm "$H/calls"
out="$(install)"
check "other versions installed: left alone" not grep -q -e '^npm' -e 'clone' -e 'reset' "$H/calls"
check "other versions installed: noted against the pin" \
  test "$(grep -c 'left as is' <<<"$out")" -eq 2

new_home; debian_bashrc
rm "$H/bin/npm" "$H/bin/bun"
out="$(install)"; rc=$?
check "no npm/bun: tools skipped with a hint" \
  bash -c 'grep -q "skip: caveman needs Node + npm" <<<"$1" && grep -q "skip: gstack needs bun" <<<"$1"' _ "$out"
check "no npm/bun: still exits 0" test "$rc" -eq 0
check "no npm/bun: nothing installed" not test -e "$H/.claude/skills/gstack" -o -e "$H/.caveman"

new_home; debian_bashrc
touch "$H/npm-fails"
out="$(install)"; rc=$?
check "caveman install fails: exits 1" test "$rc" -eq 1
check "caveman install fails: reported" grep -q "fail: caveman" <<<"$out"
check "caveman install fails: gstack still installed" grep -q "^gstack-setup" "$H/calls"

new_home; debian_bashrc
touch "$H/setup-fails"
out="$(install)"; rc=$?
check "gstack setup fails: exits 1" test "$rc" -eq 1
check "gstack setup fails: half-install removed so a re-run retries" \
  not test -e "$H/.claude/skills/gstack"
check "gstack setup fails: settings.json still restored" settings_intact

new_home; debian_bashrc
install --dry-run >/dev/null
check "dry run: calls no installer" not test -e "$H/calls"
check "dry run: settings.json not linked" not test -e "$H/.claude/settings.json"

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
  # caveman.env finds the hook through this link, as install.sh would make it.
  mkdir -p "$H/.claude"
  ln -s "$D/claude/hooks" "$H/.claude/hooks"
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

new_home; fake_caveman
rm "$H/.claude/hooks"
err="$(in_fake bash -c '. "$1"' _ "$D/claude/local/caveman.env" 2>&1)"
check "no ~/.claude/hooks link: caveman.env stays silent" test -z "$err"
check "no ~/.claude/hooks link: caveman.env leaves the API direct" test -z "$(env_url)"

# The point of the zsh support: both files must actually work when zsh sources them.
if [ -n "$ZSH_BIN" ]; then
  new_home; fake_caveman
  zsh_source() {
    in_fake "$ZSH_BIN" -fc '. "$1"; . "$2"; alias gp; print -r -- "${ANTHROPIC_BASE_URL:-}"' \
      _ "$D/shell/bash_aliases" "$D/claude/local/caveman.env"
  }
  out="$(zsh_source 2>/dev/null)"
  check "zsh: aliases load" grep -Fqx "gp='git push'" <<<"$out"
  check "zsh: caveman.env sets the proxy URL" grep -Fqx "http://127.0.0.1:8787/w/claude" <<<"$out"
  check "zsh: no errors while sourcing" test -z "$(zsh_source 2>&1 >/dev/null)"
else
  echo "  skip  zsh sourcing (zsh not installed here; runs on macOS)"
fi

echo "git"

if [ -n "$REAL_GIT" ]; then
  # Read the resulting global config with real git. --includes: with --global,
  # `git config` skips [include] unless asked (normal git commands follow it).
  gitc() { HOME="$H" "$REAL_GIT" config --global --includes "$@"; }

  new_home
  install >/dev/null
  check "fresh: ~/.gitconfig starts with the shared include" \
    test "$(head -2 "$H/.gitconfig")" = "$(printf '[include]\n\tpath = %s' "$D/git/gitconfig")"
  check "fresh: shared defaults apply" test "$(gitc init.defaultBranch)" = main
  check "fresh: global ignore linked" \
    test "$(readlink -f "$H/.config/git/ignore")" = "$(readlink -f "$D/git/ignore")"
  HOME="$H" "$REAL_GIT" init -q "$H/r"
  check "fresh: git init really uses the shared default branch" \
    test "$(HOME="$H" "$REAL_GIT" -C "$H/r" symbolic-ref HEAD)" = refs/heads/main
  check "fresh: .DS_Store ignored in any repo" \
    env HOME="$H" "$REAL_GIT" -C "$H/r" check-ignore -q .DS_Store

  new_home
  printf '[user]\n\tname = Me\n[init]\n\tdefaultBranch = trunk\n' > "$H/.gitconfig"
  mkdir -p "$H/.config/git" && echo old-ignore > "$H/.config/git/ignore"
  install >/dev/null
  check "existing: machine's own settings kept" test "$(gitc user.name)" = Me
  check "existing: machine's settings win over shared ones" test "$(gitc init.defaultBranch)" = trunk
  check "existing: shared settings fill the gaps" test "$(gitc pull.rebase)" = false
  check "existing: old global ignore backed up" \
    grep -qx old-ignore "$H"/.claude/.dotfiles-backups/*/.config/git/ignore
  install >/dev/null
  check "re-run: include not duplicated" test "$(count "$D/git/gitconfig" "$H/.gitconfig")" -eq 1
  mv "$D" "$H/moved"
  check "moved repo: git config still loads, silently" test "$(gitc user.name 2>&1)" = Me

  new_home
  install --dry-run >/dev/null
  check "dry run: no ~/.gitconfig written" not test -e "$H/.gitconfig"
  check "dry run: no global ignore linked" not test -e "$H/.config/git/ignore"
else
  echo "  skip  git (git not installed)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
