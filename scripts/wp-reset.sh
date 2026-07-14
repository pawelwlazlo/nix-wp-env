#!/usr/bin/env bash
# scripts/wp-reset.sh — the nix-wp-env devenv task `wp:reset` (NER-211).
# Drops and recreates the WordPress database, then reinstalls WordPress
# with the same parameters `wp:setup` uses. This is a manual, destructive
# task (`devenv tasks run wp:reset`) meant for an already-bootstrapped
# stack — it does not scaffold vendor/, .env, or the database from scratch
# the way scripts/wp-setup.sh does.
#
# The MariaDB wait loop, the `wp core install` call, and the closing
# summary are factored into scripts/wp-install.sh so this script reuses the
# exact same logic scripts/wp-setup.sh uses, instead of duplicating it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# ── Step 1/5: require .env ────────────────────────────────────────────────
echo "==> [1/5] checking for .env"
env_file="$repo_root/.env"
if [ ! -f "$env_file" ]; then
  echo "ERROR: .env not found at $env_file — wp:reset assumes an already-bootstrapped stack. Run 'devenv tasks run wp:setup' first." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$env_file"
set +a

# ── Step 2/5: wait for MariaDB ────────────────────────────────────────────
echo "==> [2/5] waiting for MariaDB"
# shellcheck source=/dev/null
source "$repo_root/scripts/wp-install.sh"
wait_for_mariadb

# ── Step 3/5: drop + recreate the database ────────────────────────────────
echo "==> [3/5] resetting database '$DB_NAME'"
wp db reset --yes
echo "    database '$DB_NAME' dropped and recreated"

# ── Step 4/5: guarded wp core install (shared with wp:setup) ─────────────
echo "==> [4/5] wp core install"
wp_core_install_guarded

# ── Step 5/5: summary (shared with wp:setup) ──────────────────────────────
echo "==> [5/5] summary"
wp_print_summary
