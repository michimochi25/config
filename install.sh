#!/usr/bin/env bash
#
# Apply this repo's Claude Code config to ~/.claude, plus shared shell aliases.
#
# Symlinks authored config into place so that edits made via /config flow back
# into git. Existing real files are backed up, never overwritten in place.
#
#   ./install.sh            # settings, hooks, MCP, aliases, caveman + gstack
#   ./install.sh --dry-run  # show what would happen, change nothing
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_JSON="$HOME/.claude.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Backups live outside skills/, agents/ and commands/ — a backup left beside a
# skill gets picked up by Claude Code as a second, duplicate skill.
BACKUP_DIR="$CLAUDE_DIR/.dotfiles-backups/$STAMP"

# Versions a fresh machine gets. An existing install is never changed to match:
# it may have been upgraded on purpose (gstack upgrades itself via /gstack-upgrade).
# Bump these deliberately — claude/hooks/caveman depends on caveman's file layout.
CAVEMAN_VERSION="1.2.1"
GSTACK_REF="85fd9db554ae4aaaa6d356d2daf873121ee85bdd"  # v1.68.3.0
GSTACK_REPO="https://github.com/garrytan/gstack.git"
GSTACK_DIR="$CLAUDE_DIR/skills/gstack"

# Where our source lines go, by login shell. macOS defaults to zsh, which never
# reads ~/.bashrc; zsh has no ~/.bash_aliases convention, so both go in ~/.zshrc.
case "${SHELL##*/}" in
  zsh) SHELL_RC="$HOME/.zshrc";  ALIASES_RC="$HOME/.zshrc" ;;
  *)   SHELL_RC="$HOME/.bashrc"; ALIASES_RC="$HOME/.bash_aliases" ;;
esac

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then say "would: $*"; else "$@"; fi; }

# Symlink $1 -> $2, backing up anything real already sitting at $2.
link() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    if [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
      say "ok:   $dest (already linked)"
      return
    fi
    run rm "$dest"
  elif [ -e "$dest" ]; then
    # Mirror the path under $HOME: two files share the basename settings.json
    # (Claude's and VS Code's), and a flat backup would overwrite one with the other.
    local saved="$BACKUP_DIR/${dest#"$HOME"/}"
    run mkdir -p "$(dirname "$saved")"
    run mv "$dest" "$saved"
    say "saved: $dest -> $saved"
  fi
  run ln -s "$src" "$dest"
  say "link: $dest -> $src"
}

# Append a line sourcing $2 to file $1 (once), under comment $3.
# Used instead of link() for shell files a machine may already have its own
# content in: that content stays, ours is loaded alongside it.
ensure_sourced() {
  local file="$1" src="$2" label="$3"
  # Also accept the ~/… spelling: older docs told people to add it by hand.
  local tilde_src="~${src#"$HOME"}"
  if grep -Fqs -e "$src" -e "$tilde_src" "$file"; then
    say "ok:   $file already sources $src"
    return
  fi
  # Guarded, so moving or deleting the repo doesn't break every new shell.
  local line="[ -f \"$src\" ] && . \"$src\""
  if [ "$DRY_RUN" -eq 1 ]; then
    say "would: append '$line' to $file"
    return
  fi
  printf '\n# %s\n%s\n' "$label" "$line" >> "$file"
  say "added: $file now sources $src"
}

# Like run(), but inside directory $1.
run_in() {
  local dir="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then say "would: (cd $dir && $*)"; else (cd "$dir" && "$@"); fi
}

# Run "$@", then undo any change it made to settings.json and show what it tried.
# Third-party installers write there, but it is this repo's file (via symlink),
# and caveman's edit — an unconditional proxy URL — would break machines without it.
protect_settings() {
  local live="$CLAUDE_DIR/settings.json" own="$REPO/claude/settings.json" snap rc=0
  # Nothing gets installed in a dry run, and settings.json may not be linked yet.
  if [ "$DRY_RUN" -eq 1 ]; then "$@"; return; fi
  snap="$(mktemp)"
  cp "$own" "$snap"
  "$@" || rc=$?
  if ! cmp -s "$snap" "$live" || ! cmp -s "$snap" "$own"; then
    say "note: reverted its edits to settings.json — copy across by hand if wanted:"
    diff -u "$snap" "$live" | sed 's/^/        /' || true
    cat "$snap" > "$own"
    # An installer that writes atomically replaces our symlink with a real file.
    if [ "$(readlink -f "$live")" != "$(readlink -f "$own")" ]; then
      rm -f "$live" && ln -s "$own" "$live"
    fi
  fi
  rm -f "$snap"
  return "$rc"
}

# Install the caveman CLI and/or its native binaries, whichever is missing.
# Steps are chained with && because callers run this where `set -e` is off.
install_caveman() {
  local proxy="$HOME/.caveman/bin/caveman-proxy" have
  if command -v caveman >/dev/null && [ -x "$proxy" ]; then
    have="$(caveman version 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
    if [ "$have" = "$CAVEMAN_VERSION" ]; then say "ok:   caveman $have"
    else say "ok:   caveman ${have:-?} (pin is $CAVEMAN_VERSION; left as is)"; fi
    return
  fi
  if ! command -v caveman >/dev/null; then
    if ! command -v npm >/dev/null; then
      say "skip: caveman needs Node + npm — install Node (e.g. via nvm), then re-run"
      return
    fi
    run npm install -g "@caveman-ai/cli@$CAVEMAN_VERSION" || return
    hash -r
    if [ "$DRY_RUN" -eq 0 ] && ! command -v caveman >/dev/null; then
      say "fail: npm installed caveman, but npm's global bin dir isn't on PATH"
      return 1
    fi
  fi
  run caveman setup --install
}

# Clone gstack at the pinned commit and run its setup. Stays on branch main
# (reset, not checkout) so /gstack-upgrade can still fast-forward it later.
install_gstack() {
  local have tool
  if [ -d "$GSTACK_DIR" ]; then
    have="$(git -C "$GSTACK_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [ "$have" = "$GSTACK_REF" ]; then say "ok:   gstack ${have:0:7}"
    else say "ok:   gstack ${have:0:7} (pin is ${GSTACK_REF:0:7}; left as is)"; fi
    return
  fi
  for tool in git bun; do
    if ! command -v "$tool" >/dev/null; then
      say "skip: gstack needs $tool — install it (Bun: https://bun.sh), then re-run"
      return
    fi
  done
  # setup runs from inside its own dir, as gstack's docs do it.
  if ! { run git clone -q --single-branch --branch main "$GSTACK_REPO" "$GSTACK_DIR" \
        && run git -C "$GSTACK_DIR" reset -q --hard "$GSTACK_REF" \
        && run_in "$GSTACK_DIR" ./setup; }; then
    # Remove the half-install, or the next run would see the dir and skip it.
    rm -rf "$GSTACK_DIR"
    return 1
  fi
}

echo "Installing Claude Code config from $REPO"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — nothing will change)"

run mkdir -p "$CLAUDE_DIR"

echo
echo "settings + hooks"
link "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json"
link "$REPO/claude/CLAUDE.md"     "$CLAUDE_DIR/CLAUDE.md"
link "$REPO/claude/hooks"         "$CLAUDE_DIR/hooks"

# Standalone skills authored/vendored here. Linked individually so gstack's own
# skill directory (and account-synced skills) are left untouched.
echo
echo "skills"
run mkdir -p "$CLAUDE_DIR/skills"
for skill in "$REPO"/claude/skills/*/; do
  [ -d "$skill" ] || continue
  link "${skill%/}" "$CLAUDE_DIR/skills/$(basename "$skill")"
done

# A tool that fails to install is reported and the rest carries on; the script
# then exits non-zero so the failure isn't missed. Runs before the MCP merge so
# our servers.json has the last word over caveman's own MCP entry.
echo
echo "tools"
FAILED=0
protect_settings install_caveman || { say "fail: caveman install failed (see above)"; FAILED=1; }
protect_settings install_gstack  || { say "fail: gstack install failed (see above)"; FAILED=1; }

# MCP servers live in ~/.claude.json alongside a lot of machine state, so merge
# our entries in rather than replacing the file.
echo
echo "mcp servers"
if [ "$DRY_RUN" -eq 1 ]; then
  say "would: merge $REPO/claude/mcp/servers.json into $CLAUDE_JSON"
else
  python3 - "$CLAUDE_JSON" "$REPO/claude/mcp/servers.json" <<'PY'
import json, os, sys

target, source = sys.argv[1], sys.argv[2]

config = {}
if os.path.exists(target):
    with open(target) as fh:
        config = json.load(fh)

with open(source) as fh:
    servers = json.load(fh)

existing = config.setdefault("mcpServers", {})
changed = []
for name, spec in servers.items():
    spec = json.loads(json.dumps(spec).replace("${HOME}", os.path.expanduser("~")))
    if existing.get(name) != spec:
        existing[name] = spec
        changed.append(name)

if changed:
    tmp = target + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(config, fh, indent=2)
    os.replace(tmp, target)
    print("  set:  " + ", ".join(changed))
else:
    print("  ok:   mcp servers already current")
PY
fi

echo
echo "shell aliases"
ensure_sourced "$ALIASES_RC" "$REPO/shell/bash_aliases" "Shared aliases (dotfiles)"
# Debian/Ubuntu's default ~/.bashrc loads ~/.bash_aliases; other setups may not,
# in which case the aliases would silently never load. Comments are skipped:
# Debian's bashrc also mentions .bash_aliases in a comment above the real load.
if [ "$ALIASES_RC" = "$HOME/.bash_aliases" ] \
    && ! grep -v '^[[:space:]]*#' "$HOME/.bashrc" 2>/dev/null | grep -Fq ".bash_aliases"; then
  say "note: ~/.bashrc doesn't load ~/.bash_aliases — add this to it:"
  say "      [ -f ~/.bash_aliases ] && . ~/.bash_aliases"
fi

echo
echo "caveman proxy"
# Safe to apply everywhere: caveman.env only redirects the API when caveman is
# installed, so on a machine without it Claude Code talks to the API directly.
ensure_sourced "$SHELL_RC" "$REPO/claude/local/caveman.env" "Claude Code: local caveman proxy (dotfiles)"

cat <<EOF

Done. Not handled here — see README:
  - plugins and synced skills install themselves on next \`claude\` launch
  - Node/npm and Bun are prerequisites, not installed by this script
EOF
exit "$FAILED"
