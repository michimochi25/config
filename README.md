# dotfiles

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

## What's deliberately *not* in here

`~/.claude` is ~1.4 GB, and almost none of it is authored config:

- **`skills/gstack/`** (1.3 GB) and the ~55 alias skill directories it
  generates — a git clone with `node_modules` and browser binaries. Reinstalled
  by the bootstrap below.
- **`plugins/`** — marketplace clones, rebuilt automatically from the
  `enabledPlugins` and `extraKnownMarketplaces` entries in `settings.json`.
- **`skills/synced/`, `plugins/synced/`** — pushed down from your Anthropic
  account at login.
- **`.credentials.json`, `history.jsonl`, `sessions/`, `projects/`,
  `shell-snapshots/`** — secrets and private conversation history. These must
  never be committed; `.gitignore` guards the repo root against them.

## The global CLAUDE.md

`claude/CLAUDE.md` is user-level memory: Claude Code loads it into *every*
session on this machine, so it stays short and holds only things true across
all projects. A project's own `CLAUDE.md` overrides it.

Its contents are derived from existing per-project memories rather than
invented — leading with a recommendation, staying inside the requested scope,
verifying at the process rather than the config, and no co-author trailers. The
skill-routing table was duplicated verbatim in two project files; it describes
which tools are installed on the machine, so it belongs here instead.

## The finish chime

The `Stop` hook runs `claude/hooks/notify-sound` when Claude finishes a turn.
It tries `afplay`, then `paplay`/`pw-play`, then PowerShell, then the terminal
bell, and exits 0 whichever way it goes — a machine with no working audio stays
silent rather than erroring once per turn.

On WSL2 only the PowerShell path works: there is no PipeWire daemon and no ALSA
card, so `pw-play` and `aplay` both fail. That route costs ~0.5s of PowerShell
startup plus the length of the clip, so the hook is marked `"async": true` and
does not hold up the end of a turn.

`Stop` also fires on `/clear`, resume and compact, so those chime too. To change
the sound, edit the three `*_SOUND` constants at the top of the script.

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

## Notes on the work machine

Three things from the personal setup were changed or dropped on purpose:

- **`permissions` is unset.** The personal machine runs
  `defaultMode: bypassPermissions` with `skipDangerousModePermissionPrompt`,
  which auto-approves every tool call. That is a poor default to carry onto a
  corporate machine, so the repo ships no `permissions` block and Claude Code
  prompts normally. Set it locally if your workplace allows.
- **The `Notification` hook was removed.** It ran
  `afplay /System/Library/Sounds/Glass.aiff`, which is macOS-only and was
  already dead on WSL. `preferredNotifChannel: terminal_bell` covers it.
- **Hook paths are `$HOME`-relative.** The originals hardcoded
  `/home/giselle/...` and a pinned `node/v20.19.3` path; neither survives a
  different username or Node version.
