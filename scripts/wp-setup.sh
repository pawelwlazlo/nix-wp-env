#!/usr/bin/env bash
# scripts/wp-setup.sh — idempotent bootstrap for the nix-wp-env devenv task
# `wp:setup` (NER-211). Takes a cold checkout to a working, installed
# WordPress site. Every step is individually guarded so re-running this
# script makes no destructive change.
#
# Steps: composer install -> .env + salts -> wait for MariaDB -> ensure DB
# exists -> guarded `wp core install` -> print summary.
#
# The `wp core install` call and the closing summary are factored into
# scripts/wp-install.sh so scripts/wp-reset.sh (NER-211 task 2) can reuse the
# exact same invocation instead of duplicating it.

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
db_host="${DB_HOST:-127.0.0.1}"
max_tries=30
tries=0
until mysqladmin ping -h "$db_host" -u"$DB_USER" -p"$DB_PASSWORD" --silent >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge "$max_tries" ]; then
    echo "ERROR: MariaDB not reachable at $db_host after ${max_tries}s — giving up" >&2
    exit 1
  fi
  sleep 1
done
echo "    MariaDB is reachable at $db_host"

# ── Step 4/6: ensure DB exists ────────────────────────────────────────────
echo "==> [4/6] ensuring database '$DB_NAME' exists"
if wp db check --quiet >/dev/null 2>&1; then
  echo "    database '$DB_NAME' already present"
else
  wp db create
  echo "    created database '$DB_NAME'"
fi

# ── Steps 5-6/6: guarded wp core install + summary (shared with wp:reset) ──
echo "==> [5/6] wp core install"
# shellcheck source=/dev/null
source "$repo_root/scripts/wp-install.sh"
wp_core_install_guarded

echo "==> [6/6] summary"
wp_print_summary
