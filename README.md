# config

Portable Claude Code configuration and shell aliases, so the same setup works
on a personal and a work machine.

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
| `claude/local/caveman.env` | sourced from `~/.bashrc` | Local proxy env vars, only active when caveman is installed |
| `shell/bash_aliases` | sourced from `~/.bash_aliases` | Shared shell aliases |

`install.sh` symlinks rather than copies, so anything changed later via
`/config` lands back in the repo as a normal diff. Real files already at a
destination are moved aside to `~/.claude/.dotfiles-backups/<timestamp>/<name>`
first. Use `--dry-run` to preview.

The two shell files are the exception: a machine may already have its own
`~/.bashrc` and `~/.bash_aliases`, so instead of replacing them `install.sh`
appends one guarded `source` line to each (once — re-running is a no-op; if the
repo is moved, the old line just does nothing). Existing aliases are kept. An
alias here overrides a same-named one earlier in `~/.bash_aliases`, since ours
loads last in that file; anything defined later in `~/.bashrc` still wins over
it.

Both files are loaded only by interactive shells — the stock `~/.bashrc` exits
early otherwise — so a `claude` started from a script or cron gets neither the
aliases nor the proxy.

## Tools: gstack and caveman

`install.sh` also installs these two, on every machine:

- **gstack** — supplies `/ship`, `/review`, `/browse`, `/qa` and the rest of the
  suite, plus the hooks referenced in `settings.json`. Needs git and Bun.
- **caveman** — context compression. Provides the `caveman-mcp` server that
  `claude/mcp/servers.json` points at, the `@caveman-ai/cli` hook adapter, and
  the proxy below. Needs Node + npm.

How it behaves:

- **Pinned for fresh installs.** `CAVEMAN_VERSION` and `GSTACK_REF` at the top
  of `install.sh` are what a new machine gets. gstack is cloned on `main` and
  reset to the pin, so `/gstack-upgrade` can still fast-forward it.
- **Existing installs are left alone**, even at a different version — they may
  have been upgraded on purpose. A note shows the difference.
- **Missing prerequisites are reported, not installed.** No Node or Bun means
  that tool is skipped with a hint; the rest of the install carries on. Install
  the prerequisite and re-run.
- **settings.json stays the repo's.** Both tools' own installers edit
  `~/.claude/settings.json` (caveman adds the proxy URL unconditionally, gstack
  registers hooks). Since that file is this repo's, `install.sh` reverts their
  edits and prints the diff, so you can copy across anything worth keeping.
- **A failed install** is reported and makes `install.sh` exit non-zero; a
  half-cloned gstack is removed so the next run retries.

Both stay optional at runtime: the hook wrappers exit quietly when either tool
is missing, so a machine where they were skipped still works.

Because caveman is installed everywhere, every machine with Node ends up
routing API traffic through the caveman proxy (see below).

## The caveman proxy

A machine with caveman installed routes all API traffic through a local proxy
(`ANTHROPIC_BASE_URL=http://127.0.0.1:8787/w/claude`). That only works when the
proxy can run, so it is kept out of `settings.json` and lives in
`claude/local/caveman.env`, which `install.sh` sources from `~/.bashrc` on every
machine. The file only sets the proxy URL when `claude/hooks/caveman --check`
passes — i.e. the hook that starts the proxy is able to run — so a machine
without caveman keeps talking to the API directly.

`--check` needs `caveman` on `PATH`, and caveman is usually installed under nvm.
So the caveman line in `~/.bashrc` must come **after** nvm's setup. If you
install nvm after running `install.sh`, nvm's installer appends below our line
and the proxy silently stays off — move our line to the end of `~/.bashrc`.

Check the proxy is listening with
`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/` — any code
(even 404) means up, `000` means down.

The caveman *hooks* stay in `settings.json` unconditionally. They route through
`claude/hooks/caveman`, which resolves the CLI adapter from whatever Node the
`caveman` shim lives under and exits 0 when caveman isn't installed — so no Node
version is pinned and the entries are inert without it.
