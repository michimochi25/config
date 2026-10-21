# config

Portable Claude Code configuration, shell aliases, git defaults and VS Code
settings, so the same setup works on a personal and a work machine — Linux/WSL
or macOS.

```bash
git clone https://github.com/michimochi25/config.git ~/config
cd ~/config
./install.sh
```

Then launch `claude` once — it pulls down the plugins and account-synced skills
on its own. On a fresh Mac, follow [Setting up a new Mac](#setting-up-a-new-mac)
instead: the order matters.

## What's in here

| Path | Installed to | What it is |
| --- | --- | --- |
| `claude/settings.json` | `~/.claude/settings.json` | Model, effort, theme, plugins, hooks |
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Global working agreement, loaded into every session |
| `claude/hooks/` | `~/.claude/hooks/` | Guarded wrappers for the caveman and gstack hooks, plus the turn-finished chime |
| `claude/skills/` | `~/.claude/skills/<name>` | Standalone skills (currently `playwright-cli`) |
| `claude/mcp/servers.json` | merged into `~/.claude.json` | Local MCP servers |
| `claude/local/caveman.env` | sourced from `~/.bashrc` / `~/.zshrc` | Local proxy env vars, only active when caveman is installed |
| `shell/bash_aliases` | sourced from `~/.bash_aliases` / `~/.zshrc` | Shared shell aliases (plain POSIX, so zsh reads them too); macOS-only ones are behind a `uname` check |
| `git/gitconfig` | included from the top of `~/.gitconfig` | Shared git defaults; the machine's own settings override them |
| `git/ignore` | `~/.config/git/ignore` | Global gitignore (`.DS_Store`, local Claude settings) |
| `vscode/settings.json` | `~/Library/Application Support/Code/User/settings.json` | VS Code user settings — **macOS only** |
| `vscode/extensions.txt` | installed with `code --install-extension` | VS Code extensions, missing ones only — **macOS only** |
| `Brewfile` | run by hand: `brew bundle` | macOS CLI tools and apps |

`install.sh` symlinks rather than copies, so anything changed later via
`/config` or VS Code's Settings UI lands back in the repo as a normal diff. Real
files already at a destination are moved aside to
`~/.claude/.dotfiles-backups/<timestamp>/<path under ~>` first. Use `--dry-run`
to preview.

The shell files are the exception: a machine may already have its own, so
instead of replacing them `install.sh` appends one guarded `source` line (once —
re-running is a no-op; if the repo is moved, the old line just does nothing).
Which file depends on your login shell (`$SHELL`):

- **bash** (Linux/WSL): aliases from `~/.bash_aliases`, caveman from `~/.bashrc`.
  An alias here overrides a same-named one earlier in `~/.bash_aliases`;
  anything defined later in `~/.bashrc` still wins over it.
- **zsh** (macOS default): both from `~/.zshrc`. zsh never reads `~/.bashrc`.

These files are loaded only by interactive shells, so a `claude` started from a
script or cron gets neither the aliases nor the proxy.

`~/.gitconfig` is handled the same way: an `[include]` is added at its top
rather than the file being replaced, so each machine keeps its own `user.name`
and `user.email` (e.g. a work email on the work machine), and anything it sets
overrides the shared defaults.

VS Code is only set up on macOS. On WSL its user settings live on the Windows
side, where a Linux symlink can't reach, so `install.sh` skips it there.

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
`claude/local/caveman.env`, which `install.sh` sources from `~/.bashrc` (or
`~/.zshrc`) on every machine. The file only sets the proxy URL when
`claude/hooks/caveman --check` passes — i.e. the hook that starts the proxy is
able to run — so a machine without caveman keeps talking to the API directly.

`--check` needs `caveman` on `PATH`, and caveman is usually installed under nvm.
So the caveman line in `~/.bashrc` / `~/.zshrc` must come **after** nvm's
setup. If you install nvm after running `install.sh`, nvm's installer appends
below our line and the proxy silently stays off — move our line to the end of
the file.

Check the proxy is listening with
`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/` — any code
(even 404) means up, `000` means down.

The caveman *hooks* stay in `settings.json` unconditionally. They route through
`claude/hooks/caveman`, which resolves the CLI adapter from whatever Node the
`caveman` shim lives under and exits 0 when caveman isn't installed — so no Node
version is pinned and the entries are inert without it.

## Setting up a new Mac

Do these in order — each step needs the ones before it. Open a **new terminal**
whenever a step edits your shell startup files.

1. **Command Line Tools** (git, python3, a C compiler): `xcode-select --install`
2. **Homebrew**: install from <https://brew.sh>, then run the commands it prints
   under "Next steps" (they add `brew` to `~/.zprofile`). Skip them and `brew`
   isn't on PATH.
3. **This repo**, over HTTPS since there's no SSH key yet:
   `git clone https://github.com/michimochi25/config.git ~/config`
4. **Tools and apps**: `brew bundle --file ~/config/Brewfile`
   (Docker Desktop asks for your password).
5. **Oh My Zsh** — its installer writes a fresh `~/.zshrc` (the old one is kept
   as `~/.zshrc.pre-oh-my-zsh`), so do this before anything else edits that file:
   ```bash
   sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
   ```
   Then make the top of `~/.zshrc` look like this. Docker's completions must be
   on `fpath` before Oh My Zsh loads, because it runs `compinit` itself:
   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)"

   # Docker CLI completions
   fpath=($HOME/.docker/completions $fpath)

   # Oh My Zsh
   export ZSH="$HOME/.oh-my-zsh"
   ZSH_THEME="cloud"
   plugins=(git)
   source $ZSH/oh-my-zsh.sh

   export CLICOLOR=1
   export LSCOLORS=Gxfxcxdxbxegedabagacad
   ```
6. **nvm + Node** — before `install.sh`, which installs caveman with npm and
   must put its line in `~/.zshrc` *below* nvm's:
   ```bash
   touch ~/.zshrc   # nvm's installer only edits a startup file that already exists
   # install nvm: https://github.com/nvm-sh/nvm#installing-and-updating — then, in a new terminal:
   nvm install 24 && nvm alias default 24
   npm install -g vercel @playwright/cli
   ```
   Homebrew's `nvm` (`brew install nvm`) also works, though nvm doesn't
   officially support it: it edits no startup file, so add the lines from
   `brew info nvm` to `~/.zshrc` yourself, still above this repo's lines:
   ```bash
   export NVM_DIR="$HOME/.nvm"
   [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
   [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
   ```
7. **Rust**: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
8. **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash`. If `claude`
   isn't found afterwards, add `export PATH="$HOME/.local/bin:$PATH"` as the last
   line of `~/.zshrc`.
9. **This config**, then prove it works on this machine:
   ```bash
   cd ~/config && ./install.sh && ./tests/install_test.sh
   ```
   If caveman has no macOS build, `install.sh` reports a caveman failure and
   exits 1; everything else is still installed and Claude Code talks to the API
   directly (the proxy stays off).
10. **Per-machine identity** (never in this repo):
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email you@example.com
   gh auth login && gh auth setup-git        # git over HTTPS uses gh's login

   ssh-keygen -t ed25519                     # a new key per machine; don't copy old ones
   ssh-add --apple-use-keychain ~/.ssh/id_ed25519
   gh ssh-key add ~/.ssh/id_ed25519.pub
   ```
   Add to `~/.ssh/config` so the key loads from the Keychain after a reboot:
   ```
   Host *
     AddKeysToAgent yes
     UseKeychain yes
     IdentityFile ~/.ssh/id_ed25519
   ```
   Then put the public key on any other SSH host you use
   (`ssh-copy-id <user>@<host>`), open Docker Desktop once to finish its setup,
   and run `claude` to log in.
11. **Check**, in a new terminal:
    - `alias gp` prints `gp='git push'`
    - `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/` after
      starting `claude` — any code but `000` means the caveman proxy is up
    - change any setting in VS Code's Settings UI, then run
      `ls -l ~/Library/Application\ Support/Code/User/settings.json` — it should
      still be a link (`->`). If VS Code replaced it with a real file, re-run
      `install.sh` (it backs that file up and relinks) and copy your change across.
