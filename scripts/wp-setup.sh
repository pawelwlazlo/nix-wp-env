#!/usr/bin/env bash
# scripts/wp-setup.sh — idempotent bootstrap for the nix-wp-env devenv task
# `wp:setup` (NER-211). Takes a cold checkout to a working, installed
# WordPress site. Every step is individually guarded so re-running this
# script makes no destructive change.
#
# Steps: composer install -> .env + salts -> wait for MariaDB -> ensure DB
# exists -> guarded `wp core install` -> print summary.
#
# The MariaDB wait loop, the `wp core install` call, and the closing summary
# are factored into scripts/wp-install.sh so scripts/wp-reset.sh (NER-211
# task 2) can reuse the exact same logic instead of duplicating it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# ── Step 1/6: composer install ────────────────────────────────────────────
echo "==> [1/6] composer install"
if [ -d vendor ] && [ -d web/wp ]; then
  echo "    vendor/ and web/wp/ already present — skipping composer install"
else
  composer install --no-interaction
fi

# ── Step 2/6: .env + salts ────────────────────────────────────────────────
echo "==> [2/6] .env + salts"
env_file="$repo_root/.env"
if [ -f "$env_file" ]; then
  echo "    .env already exists — leaving it untouched"
else
  cp "$repo_root/.env.example" "$env_file"

  salt_keys=(
    AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
    AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT
  )
  tmp_env="$(mktemp "$repo_root/.env.XXXXXX")"
  for key in "${salt_keys[@]}"; do
    # Each key gets an independently generated, distinct value (base64
    # alphabet is A-Za-z0-9+/= — never contains the `|` sed delimiter, `&`,
    # or a single quote, so no extra escaping is needed here).
    value="$(openssl rand -base64 48)"
    sed "s|^${key}='generateme'\$|${key}='${value}'|" "$env_file" > "$tmp_env"
    mv "$tmp_env" "$env_file"
  done
  # .env holds DB credentials + salts; the `cp`/`mv` above leave it at the
  # umask default (typically 0644). Restrict it so it isn't world-readable.
  chmod 600 "$env_file"
  echo "    generated .env with 8 distinct salts"
fi

# From here on, DB_*/WP_* come from .env (single source of truth for the
# site URL/port — see the httpPort binding in devenv.nix).
set -a
# shellcheck source=/dev/null
source "$env_file"
set +a

# ── Step 3/6: wait for MariaDB ────────────────────────────────────────────
echo "==> [3/6] waiting for MariaDB"
# shellcheck source=/dev/null
source "$repo_root/scripts/wp-install.sh"
wait_for_mariadb

# ── Step 4/6: ensure DB exists ────────────────────────────────────────────
echo "==> [4/6] ensuring database '$DB_NAME' exists"
if wp db check --quiet >/dev/null 2>&1; then
  echo "    database '$DB_NAME' already present"
else
  wp db create
  echo "    created database '$DB_NAME'"
fi

# ── Steps 5-6/6: guarded wp core install + summary (shared with wp:reset) ──
# scripts/wp-install.sh was already sourced in step 3 (for wait_for_mariadb).
echo "==> [5/6] wp core install"
wp_core_install_guarded

echo "==> [6/6] summary"
wp_print_summary
