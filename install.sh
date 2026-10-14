#!/usr/bin/env bash
#
# Apply this repo's Claude Code config to ~/.claude, plus shared shell aliases.
#
# Symlinks authored config into place so that edits made via /config flow back
# into git. Existing real files are backed up, never overwritten in place.
#
#   ./install.sh            # settings, hooks, MCP servers, aliases, caveman proxy
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
    run mkdir -p "$BACKUP_DIR"
    run mv "$dest" "$BACKUP_DIR/$(basename "$dest")"
    say "saved: $dest -> $BACKUP_DIR/$(basename "$dest")"
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
ensure_sourced "$HOME/.bash_aliases" "$REPO/shell/bash_aliases" "Shared aliases (dotfiles)"
# Debian/Ubuntu's default ~/.bashrc loads ~/.bash_aliases; other setups may not,
# in which case the aliases would silently never load. Comments are skipped:
# Debian's bashrc also mentions .bash_aliases in a comment above the real load.
if ! grep -v '^[[:space:]]*#' "$HOME/.bashrc" 2>/dev/null | grep -Fq ".bash_aliases"; then
  say "note: ~/.bashrc doesn't load ~/.bash_aliases — add this to it:"
  say "      [ -f ~/.bash_aliases ] && . ~/.bash_aliases"
fi

echo
echo "caveman proxy"
# Safe to apply everywhere: caveman.env only redirects the API when caveman is
# installed, so on a machine without it Claude Code talks to the API directly.
ensure_sourced "$HOME/.bashrc" "$REPO/claude/local/caveman.env" "Claude Code: local caveman proxy (dotfiles)"

cat <<EOF

Done. Not handled here — see README:
  - plugins and synced skills install themselves on next \`claude\` launch
  - gstack and caveman are separate installs
EOF
