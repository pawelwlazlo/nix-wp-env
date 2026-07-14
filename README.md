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
  `nix run nixpkgs#devenv --`, e.g. `nix run nixpkgs#devenv -- up --mode after -d`.

## Quick start

```bash
nix run nixpkgs#devenv -- up --mode after -d   # start PHP-FPM, MariaDB, Caddy, then bootstrap WordPress (detached)
```

`--mode after` matters: `wp:setup` is a devenv task that runs downstream of the
MariaDB process, and plain `devenv up` (the default `before` mode) does **not**
run downstream tasks — it brings the stack up but skips the WordPress
auto-install. `--mode after` is what actually runs `wp:setup` once MariaDB is
provisioned.

Then open <http://localhost:8080> — you should see an installed WordPress site
(Bedrock docroot, served by Caddy through PHP-FPM). Admin login is at
<http://localhost:8080/wp/wp-admin> (see [Admin credentials](#admin-credentials)
below for the default username/password).

```bash
nix run nixpkgs#devenv -- shell           # drop into a shell with php 8.4, composer, wp-cli on PATH
nix run nixpkgs#devenv -- processes down  # stop all three processes
```

### Bootstrap tasks (`wp:setup` / `wp:reset`)

`wp:setup` is idempotent: composer install (skipped if `vendor/`+`web/wp/`
already exist) → generate `.env` + 8 distinct salts (skipped if `.env` already
exists) → wait for MariaDB → create the `wordpress` DB if absent → guarded
`wp core install` (skipped if WordPress is already installed) → print the site
URL and admin login. Re-running it, or re-running `devenv up --mode after`, is
always safe and non-destructive.

```bash
nix run nixpkgs#devenv -- tasks run wp:setup   # manual bootstrap (same thing --mode after runs automatically)
nix run nixpkgs#devenv -- tasks run wp:reset   # clean slate: drops + recreates the DB, then reinstalls WordPress
```

`wp:reset` requires `.env` to already exist (run `wp:setup` first) — it drops
and recreates the database via `wp db reset --yes`, then reinstalls WordPress
with the same parameters `wp:setup` uses.

If `.env` generation gets interrupted mid-way, remove `.env` and re-run
`wp:setup` — an existing `.env` is left untouched, so a half-written one won't
self-heal.

### Admin credentials

`wp:setup` / `wp:reset` install WordPress with dev-safe defaults, overridable
via environment variables before running the task:

| Variable             | Default              | Notes                                                       |
|----------------------|-----------------------|--------------------------------------------------------------|
| `WP_ADMIN_USER`      | `admin`               |                                                                |
| `WP_ADMIN_PASSWORD`  | `password`            | **dev-only default — never use on an exposed environment**   |
| `WP_ADMIN_EMAIL`     | `admin@example.com`   |                                                                |
| `WP_TITLE`           | `nix-wp-env`           | site title                                                    |

The site URL itself comes from `WP_HOME` in `.env` (default
`http://localhost:8080`); admin login is at `<WP_HOME>/wp/wp-admin`.

### Teardown

```bash
nix run nixpkgs#devenv -- processes down   # stop PHP-FPM, MariaDB, and Caddy
rm -rf .devenv/state                       # wipe DB/Caddy/FPM state for a fully clean slate
```

State (MariaDB data, Caddy config, FPM socket) lives under `.devenv/state/` and
is gitignored.

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
web/            # Bedrock docroot served by Caddy (installed WordPress site after wp:setup)
docs/           # design spec and notes
```

## Roadmap

This repo is built up issue by issue (Linear project `nix-wp-env`):

- **NER-208** — this scaffold (PHP 8.4 + MariaDB + Caddy over HTTP). ✅
- **NER-209** — Bedrock application layout.
- **NER-210** — local HTTPS + `wp.localhost`.
- **NER-211** — `wp:setup` bootstrap + reset. ✅
- **NER-212** — verify script + CI (Linux).
