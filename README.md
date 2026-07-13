# nix-wp-env

Reproducible, single-site **local WordPress development** environment defined
declaratively with [Nix](https://nixos.org/) + [devenv](https://devenv.sh/). A
cold checkout boots to a working stack with one command and behaves the same on
macOS and Linux. Development only — not for production or deploy.

## Stack

| Component     | Detail                                                      |
|---------------|-------------------------------------------------------------|
| Orchestration | devenv (standard `devenv.yaml` + `devenv.nix`, no `flake.nix`) |
| PHP           | 8.4 via `languages.php` + PHP-FPM pool (`web`)              |
| Web server    | Caddy — HTTP on `:8080` (HTTPS + `wp.localhost` land in NER-210) |
| Database      | MariaDB via `services.mysql`; auto-creates the `wordpress` DB |
| Tooling       | php, composer, wp-cli on `PATH` inside the shell            |

## Prerequisites

- [Nix](https://nixos.org/download) with the `nix-command` and `flakes`
  experimental features enabled.
- devenv. If it isn't installed globally you can run it straight from nixpkgs
  (prebuilt in the binary cache) — prefix every command below with
  `nix run nixpkgs#devenv --`, e.g. `nix run nixpkgs#devenv -- up -d`.

## Quick start

```bash
devenv up -d          # start PHP-FPM, MariaDB, and Caddy (detached)
```

Then open <http://localhost:8080> — you should see the placeholder `phpinfo()`
page served by Caddy through PHP-FPM (proof the full path works).

```bash
devenv shell          # drop into a shell with php 8.4, composer, wp-cli on PATH
devenv processes down  # stop all three processes
```

State (MariaDB data, Caddy config, FPM socket) lives under `.devenv/state/` and
is gitignored. For a clean slate, `rm -rf .devenv/state` and `devenv up` again.

## Changing the HTTP port

Port `8080` is a single point of change: the `httpPort` let-binding at the top
of [`devenv.nix`](devenv.nix). Edit it there — both the Caddy vhost and the
`WP_PORT` env var follow. Do this if `8080` is already taken on your host:

```nix
let
  httpPort = "8090";  # was "8080"
in
```

## Project layout

```
devenv.yaml     # devenv inputs (pins nixpkgs); devenv.lock is committed
devenv.nix      # the environment: PHP 8.4 + FPM, MariaDB, Caddy, tooling
web/            # docroot served by Caddy (placeholder index.php for now)
docs/           # design spec and notes
```

## Roadmap

This repo is built up issue by issue (Linear project `nix-wp-env`):

- **NER-208** — this scaffold (PHP 8.4 + MariaDB + Caddy over HTTP). ✅
- **NER-209** — Bedrock application layout.
- **NER-210** — local HTTPS + `wp.localhost`.
- **NER-211** — `wp:setup` bootstrap + reset.
- **NER-212** — verify script + CI (Linux).
