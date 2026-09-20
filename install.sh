#!/usr/bin/env bash
#
# Apply this repo's Claude Code config to ~/.claude.
#
# Symlinks authored config into place so that edits made via /config flow back
# into git. Existing real files are backed up, never overwritten in place.
#
#   ./install.sh                 # settings + hooks + MCP servers
#   ./install.sh --with-caveman  # also enable the local caveman proxy in ~/.bashrc
#   ./install.sh --dry-run       # show what would happen, change nothing
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_JSON="$HOME/.claude.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Backups live outside skills/, agents/ and commands/ — a backup left beside a
# skill gets picked up by Claude Code as a second, duplicate skill.
BACKUP_DIR="$CLAUDE_DIR/.dotfiles-backups/$STAMP"

WITH_CAVEMAN=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --with-caveman) WITH_CAVEMAN=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

echo "Installing Claude Code config from $REPO"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — nothing will change)"

run mkdir -p "$CLAUDE_DIR"

echo
echo "settings + hooks"
link "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json"
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
echo "caveman proxy (optional)"
RC="$HOME/.bashrc"
SOURCE_LINE="source \"$REPO/claude/local/caveman.env\""
if [ "$WITH_CAVEMAN" -eq 1 ]; then
  if [ -f "$RC" ] && grep -Fqs "claude/local/caveman.env" "$RC"; then
    say "ok:   already enabled in $RC"
  else
    run bash -c "printf '\n# Claude Code: local caveman proxy (dotfiles)\n%s\n' '$SOURCE_LINE' >> '$RC'"
    say "added: $RC now sources claude/local/caveman.env"
    say "note: start a new shell, and make sure the proxy is running"
  fi
else
  say "skipped (pass --with-caveman to enable)"
fi

cat <<EOF

Done. Not handled here — see README:
  - plugins and synced skills install themselves on next \`claude\` launch
  - gstack and caveman are separate installs
EOF
