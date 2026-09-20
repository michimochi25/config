# config

Portable Claude Code configuration, so the same setup works on a personal and a
work machine.

```bash
git clone <this-repo> ~/projects/dotfiles
cd ~/projects/dotfiles
./install.sh
```

Then launch `claude` once — it pulls down the plugins and account-synced skills
on its own.

## What's in here

| Path | Installed to | What it is |
| --- | --- | --- |
| `claude/settings.json` | `~/.claude/settings.json` | Model, effort, theme, plugins, hooks |
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Global working agreement, loaded into every session |
| `claude/hooks/` | `~/.claude/hooks/` | Guarded wrappers for the caveman and gstack hooks, plus the turn-finished chime |
| `claude/skills/` | `~/.claude/skills/<name>` | Standalone skills (currently `playwright-cli`) |
| `claude/mcp/servers.json` | merged into `~/.claude.json` | Local MCP servers |
| `claude/local/caveman.env` | *(opt-in, see below)* | Local proxy env vars, off by default |

`install.sh` symlinks rather than copies, so anything changed later via
`/config` lands back in the repo as a normal diff. Real files already at a
destination are moved aside to `<name>.backup-<timestamp>` first. Use
`--dry-run` to preview.

## Bootstrap the rest

Neither of these is a Claude Code setting, so `install.sh` leaves them alone.
Both are optional — the hook wrappers exit quietly when either is missing, so a
work machine without them runs fine.

**gstack** (requires Bun) — supplies `/ship`, `/review`, `/browse`, `/qa` and
the rest of the suite, plus the four hooks referenced in `settings.json`:

```bash
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack \
  && cd ~/.claude/skills/gstack && ./setup
```

**caveman** — context compression. Provides the `caveman-mcp` server that
`claude/mcp/servers.json` points at, and the `@caveman-ai/cli` hook adapter.

## The caveman proxy is opt-in

The personal machine routes all API traffic through a local caveman proxy
(`ANTHROPIC_BASE_URL=http://127.0.0.1:8787/w/claude`). That only works when the
proxy is actually listening, so it is kept out of `settings.json` — a machine
without it would otherwise fail to reach the API at all.

Enable per machine:

```bash
./install.sh --with-caveman   # appends a source line to ~/.bashrc
```

The caveman *hooks* stay in `settings.json` unconditionally. They route through
`claude/hooks/caveman`, which resolves the CLI adapter from whatever Node the
`caveman` shim lives under and exits 0 when caveman isn't installed — so no Node
version is pinned and the entries are inert without it.
