# nix-wp-env — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorming → design)

## Purpose

A reproducible, single-site local **WordPress development environment** defined
declaratively with Nix. The goal is an environment you *use*, not maintain: a
cold checkout boots to a working WordPress site with one command, and behaves
the same on macOS and Linux.

Scope decisions locked during brainstorming:

- **Use case:** local WordPress **development** (not production/deploy).
- **Artifact under development:** full WordPress **sites** (themes + plugins +
  config), not a single theme or plugin in isolation.
- **Site count:** **one site at a time** per checkout (one DB, one docroot).
- **Platforms:** **macOS + Linux** (`aarch64-darwin` + `x86_64-linux` /
  `aarch64-linux`).
- **Orchestration:** **devenv** (built on Nix flakes, wraps `process-compose`).
- **WordPress layout:** **Bedrock** (Roots), Composer-managed.

## Architecture & Components

`devenv up` starts the whole stack; `devenv shell` puts PHP, Composer, and
wp-cli on `PATH`. Everything is declared with **standard devenv** — `devenv.yaml`
manages the nixpkgs input and there is **no top-level `flake.nix`** (decided
2026-07-13, NER-208).

| Component | Provided by | Role |
|-----------|-------------|------|
| Entry point | `devenv.yaml`, `devenv.nix`, `.envrc` | Declarative env definition |
| PHP-FPM | `languages.php` (v**8.4**) | Runs Bedrock; FPM pool behind Caddy |
| Web server | `services.caddy` | Serves `web/`, PHP handler, **local HTTPS** |
| Database | `services.mysql` (**MariaDB**) | The `wordpress` DB; data in `.devenv/state` |
| Tooling | wp-cli + Composer | Site management inside the shell |
| Application | Bedrock | WordPress code, tracked in git |

Each component has one clear job and a well-defined seam:

- **devenv.nix** owns *what runs* (services, versions, env). It does not contain
  site content.
- **Bedrock (`config/`, `composer.json`, `web/app`)** owns *the WordPress
  application*. It is agnostic to how the services are launched.
- **Bootstrap tasks** own *first-run state* (deps, DB, WP install). They are
  idempotent and separate from both of the above.

## Repository Layout

```
nix-wp-env/
├── devenv.yaml            # devenv inputs (nixpkgs pin) — standard devenv, no flake.nix
├── devenv.nix             # php 8.4, caddy, mysql (mariadb), tasks, env
├── .envrc                 # `use devenv` — direnv auto-load
├── .env.example           # tracked: WP_ENV, WP_HOME, DB_* (dev defaults)
├── .env                   # gitignored: real local config + generated salts
├── composer.json          # Bedrock deps (roots/bedrock, plugins)
├── composer.lock          # tracked: pinned dependency versions
├── config/                # Bedrock config (application.php, environments/)
├── web/                   # docroot (served by Caddy)
│   ├── wp/                # WP core (Composer-managed, gitignored)
│   ├── app/               # = wp-content
│   │   ├── themes/        # your themes (tracked)
│   │   ├── plugins/       # Composer-managed (gitignored) + tracked custom ones
│   │   ├── mu-plugins/
│   │   └── uploads/       # gitignored
│   ├── index.php
│   └── wp-config.php
├── docs/superpowers/specs/  # design docs
└── .gitignore             # .devenv/, .env, web/wp, vendor/, uploads/, composer plugins
```

## Services & Configuration (`devenv.nix`)

- `languages.php.enable = true`, **version 8.4**, with the extensions WordPress
  needs (mysqli, gd, mbstring, curl, dom, exif, intl, zip, …) and a PHP-FPM pool.
- `services.mysql.enable = true` with the **MariaDB** package, an
  auto-created `wordpress` database, dev credentials sourced from `.env`.
- `services.caddy.enable = true` serving `web/` with the PHP-FPM handler.
  - Hostname **`wp.localhost`** (the `.localhost` TLD resolves to `127.0.0.1`).
  - **Local HTTPS** via Caddy's internal CA (`tls internal`). Trusting the CA
    on macOS may require a one-time `caddy trust` / keychain prompt — documented
    in the README.
- `env` block exports `DB_*`, `WP_HOME=https://wp.localhost`,
  `WP_SITEURL=${WP_HOME}/wp`, `WP_ENV=development` so Bedrock's `.env`-driven
  config resolves. `.env` is the source of truth; `.env.example` is the tracked
  template.

## First-Run Bootstrap

An **idempotent** devenv task (e.g. `devenv tasks run wp:setup`, wired to run on
first `up`). Each step is guarded so repeated runs are safe:

1. `composer install` — pulls Bedrock, WP core (into `web/wp`), and plugins.
2. If `.env` is missing, generate it from `.env.example`, including fresh salts.
3. Wait for MariaDB to accept connections (bounded wait-loop with timeout);
   create the `wordpress` DB if absent.
4. `wp core install` (URL, title, admin user/pass/email) — skipped when
   `wp core is-installed` already succeeds.
5. Print the site URL (`https://wp.localhost`) and admin login details.

## Day-to-Day Workflow

- `devenv up` → stack runs; open `https://wp.localhost`.
- `devenv shell` → `wp ...`, `composer require wpackagist-plugin/<name>`, etc.
- Theme code is edited live under `web/app/themes/<your-theme>`.

## Reset, Teardown & Error Handling

- **Teardown:** stop processes; `rm -rf .devenv/state` wipes DB/service state for
  a clean slate.
- **`wp:reset` task:** drop + recreate the DB and re-run `wp core install`.
- **Guards:** bootstrap checks ("is WP installed?", "does the DB exist?", "does
  `.env` exist?") make `up` safe to repeat. DB-not-ready → bounded wait-loop;
  missing `.env` → generated on the fly.

## Testing / Verification

Reproducibility is the real acceptance test. A `verify` script (later promoted to
Linux CI) that proves a cold checkout boots to a working site:

1. `devenv up` in the background.
2. Wait for Caddy to accept connections.
3. `curl -k https://wp.localhost` expecting HTTP 200; `wp core is-installed`
   succeeds inside the shell.
4. Tear down.

## Non-Goals (YAGNI)

- Production / deployment configuration.
- Running multiple sites simultaneously or WordPress Multisite.
- Managing WordPress core or third-party plugins as *tracked* source (Composer
  owns them; only first-party themes/plugins are tracked).
