# NER-211 — Idempotent `wp:setup` bootstrap + `wp:reset` tasks

Plan for the implementation of Linear issue **NER-211** (project `nix-wp-env`,
parent NER-207). This plan is executed with subagent-driven development.

## Objective

Provide an idempotent `wp:setup` devenv task that takes a cold checkout to a
working, installed WordPress site, plus a `wp:reset` task for a clean slate — so
"clone → `devenv up` → working site" holds with no manual steps. Re-running is
always safe and non-destructive.

## Global Constraints (bind every task; reviewers get these verbatim)

- **Standard devenv, never a top-level `flake.nix`** (NER-208 decision). Add
  `tasks` to the existing `devenv.nix`; do not restructure the project.
- **Single source of truth for the port** stays the `httpPort` let-binding in
  `devenv.nix`. Do not hard-code `8080` in scripts — read the site URL from
  `$WP_HOME` (Bedrock `.env`), which already encodes the port.
- **Idempotency is mandatory.** Every step of `wp:setup` MUST be individually
  guarded so a second run makes **no destructive change**: composer install is a
  no-op when deps exist; `.env` is generated **only when absent**; the DB is
  created **only when absent**; `wp core install` is guarded by
  `wp core is-installed`.
- **Bedrock layout.** WordPress core lives under `web/wp`; wp-cli must be told
  this via a repo-root `wp-cli.yml` (`path: web/wp`). Config + salts live in
  `.env` (loaded by `config/application.php`), NOT in `wp-config.php` — so
  `wp config shuffle-salts` does NOT apply here; salts go into `.env`.
- **No network dependency for salts.** Generate salts locally with `openssl`;
  do not fetch from the WordPress salt API (keeps cold-boot offline-safe).
- **Non-interactive.** Every `wp`/`mysql` call runs unattended (no prompts):
  use `--yes` where applicable and `--skip-email` on install.
- **Bounded waits only.** The MariaDB wait-loop MUST have a finite timeout and
  fail loudly (non-zero exit + clear message) if the DB never comes up — never
  loop forever.
- **devenv task references must evaluate.** Depend on `devenv:mysql:configure`
  (already referenced by `processes.caddy.after` in this repo, so known-good),
  not on an unverified `@ready` probe.

## Technical Approach

Two devenv tasks backed by small, self-guarding shell scripts under `scripts/`:

- `tasks."wp:setup".exec` → `scripts/wp-setup.sh`
- `tasks."wp:reset".exec` → `scripts/wp-reset.sh`

Wiring so `wp:setup` runs on first `up`:

```nix
tasks."wp:setup" = {
  exec = "${config.devenv.root}/scripts/wp-setup.sh";
  after = [ "devenv:mysql:configure" ];
};
```

Because `wp:setup` is **downstream** of the mysql process/configure task, plain
`devenv up` (default `before` mode) does NOT run it. It runs under
**`devenv up --mode after`** (confirmed against devenv 2.1.2:
`--mode after` = "run the specified task and all tasks that depend on it"). This
becomes the documented boot command. Plain `devenv up` still brings the stack up
without auto-install; `devenv tasks run wp:setup` runs the bootstrap manually.

The in-script MariaDB wait-loop is belt-and-suspenders on top of the
`devenv:mysql:configure` ordering — it guarantees the socket actually answers
before install, independent of probe timing.

Admin credentials and site metadata come from env vars with dev-safe defaults
(documented, overridable):

| Var | Default |
|-----|---------|
| `WP_ADMIN_USER` | `admin` |
| `WP_ADMIN_PASSWORD` | `password` |
| `WP_ADMIN_EMAIL` | `admin@example.com` |
| `WP_TITLE` | `nix-wp-env` |

`WP_HOME` is read from the environment/`.env` (already set to the site URL).

## Task 1 — `wp:setup` task + script + wp-cli.yml

**Files:** `scripts/wp-setup.sh` (new, executable), `wp-cli.yml` (new),
`devenv.nix` (add `tasks."wp:setup"`).

`scripts/wp-setup.sh` must run these guarded steps in order, echoing a short
`==>` progress line before each, and exit non-zero on any hard failure
(`set -euo pipefail`):

1. **composer install** — run only if `web/wp` or `vendor` is missing
   (`[ -d vendor ] && [ -d web/wp ]` → skip). Run from repo root.
2. **`.env` + salts** — only if `.env` is absent: `cp .env.example .env`, then
   replace each of the 8 `generateme` salt placeholders
   (`AUTH_KEY`, `SECURE_AUTH_KEY`, `LOGGED_IN_KEY`, `NONCE_KEY`, `AUTH_SALT`,
   `SECURE_AUTH_SALT`, `LOGGED_IN_SALT`, `NONCE_SALT`) with an independently
   generated `openssl rand -base64 48` value. Each key must get a DISTINCT
   value (generate inside the loop, not once). If `.env` already exists, leave
   it untouched.
3. **Wait for MariaDB** — bounded loop (e.g. up to ~30 tries × 1s) polling
   `mysqladmin ping -h "$DB_HOST" ...` (or `mysqladmin ping` on the devenv
   socket). On timeout: print a clear error and exit non-zero. `DB_HOST` /
   creds come from `.env`; default host `127.0.0.1`.
4. **Ensure DB exists** — devenv already auto-creates `wordpress` via
   `initialDatabases`, so this is a guarded no-op: check with `wp db check`
   (or `mysqlshow`); only `wp db create` if the check fails.
5. **`wp core install`** — guarded by `wp core is-installed`: if already
   installed, skip. Otherwise:
   `wp core install --url="$WP_HOME" --title="$WP_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL" --skip-email`.
6. **Print summary** — always (even on a fully-idempotent re-run): the site URL
   (`$WP_HOME`), the admin login URL (`$WP_HOME/wp/wp-admin`), and the admin
   username. Do NOT print the password in plaintext beyond noting it is the
   documented dev default / `$WP_ADMIN_PASSWORD`.

`wp-cli.yml` (repo root):

```yaml
path: web/wp
```

`devenv.nix`: add the `tasks."wp:setup"` block shown in Technical Approach. Do
not remove or alter the existing `processes.caddy.after` line.

**Acceptance for Task 1:**
- Fresh state (`rm -rf .devenv/state`, no `.env`) → `devenv up --mode after` →
  site installed and reachable; second run makes no destructive change.
- `wp-cli.yml` lets `wp` locate core under `web/wp`.
- All six steps individually guarded; script uses `set -euo pipefail`.

## Task 2 — `wp:reset` task + script

**Files:** `scripts/wp-reset.sh` (new, executable), `devenv.nix`
(add `tasks."wp:reset"`).

`scripts/wp-reset.sh` (`set -euo pipefail`):

1. **Drop + recreate the DB** — `wp db reset --yes` (drops all tables and
   recreates the schema; non-interactive). Guard for DB reachability first
   (reuse the same bounded wait as setup, or require the stack to be up and
   fail clearly if not).
2. **Reinstall** — re-run `wp core install …` with the SAME parameters as
   `wp:setup` step 5 (single source of truth: factor the install invocation so
   reset and setup do not drift — e.g. a shared `scripts/wp-install.sh` helper
   sourced by both, or `wp-reset.sh` invoking `wp-setup.sh` after the drop).
3. **Print summary** — same URL + login summary as setup.

`wp:reset` is a manual task (`devenv tasks run wp:reset`); it does NOT need to be
wired into `up`.

**Acceptance for Task 2:**
- `devenv tasks run wp:reset` drops + recreates the DB and yields a clean, freshly
  installed site.
- Install parameters do not duplicate/drift from `wp:setup` (shared helper).

## Task 3 — Documentation

**Files:** `README.md` (edit).

- Update **Quick start** to make `devenv up --mode after -d` the primary boot
  command, explaining that `--mode after` is what runs the downstream
  `wp:setup` task (plain `devenv up` brings the stack up without auto-install).
- Document `devenv tasks run wp:setup` (manual bootstrap) and
  `devenv tasks run wp:reset` (clean slate).
- Document full teardown: `devenv processes down` + `rm -rf .devenv/state`.
- Document the admin-cred / `WP_TITLE` env overrides and their dev defaults, and
  note the default admin password is dev-only.
- Update the **Roadmap** line for NER-211 to ✅.
- Remember the `nix run nixpkgs#devenv --` prefix convention already in the
  README when giving commands.

## Acceptance Criteria (issue)

- [ ] `wp:setup` runs composer install → `.env`+salts (if missing) → wait for DB
  → create DB if absent → guarded `wp core install` → prints URL + login.
- [ ] Re-running `devenv up --mode after` / `wp:setup` is safe and non-destructive.
- [ ] `wp:reset` drops + recreates the DB and re-runs `wp core install`.
- [ ] Teardown documented: stop processes + `rm -rf .devenv/state`.
- [ ] Bootstrap handles missing `.env` and not-yet-ready DB gracefully.

## Risks

| Risk | Mitigation |
|------|------------|
| Install races ahead of MariaDB | `after = devenv:mysql:configure` + bounded in-script `mysqladmin ping` wait-loop before any `wp` DB call. |
| wp-cli can't find Bedrock core | Add repo-root `wp-cli.yml` with `path: web/wp`. |
| Salt generation needs network / extra wp-cli pkg | Generate locally with `openssl rand -base64 48`, one distinct value per key, written into `.env`. |
| Non-idempotent re-runs corrupt state | Guard every step (`vendor`/`web/wp` exist, `.env` exists, `wp db check`, `wp core is-installed`). |
| `wp:setup` silently not running on plain `up` | Document `devenv up --mode after` as the boot command; README explains why. |
| Reset/setup install params drift | Factor a single shared install invocation used by both. |

## Dependencies

- Builds on NER-208 (services + wp-cli), NER-209 (Bedrock + `.env`).
- HTTPS `WP_HOME` finalization is NER-210 (not blocking; script reads `$WP_HOME`).
- Feeds NER-212 (verify script drives `wp:setup`).
