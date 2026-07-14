#!/usr/bin/env bash
# scripts/wp-install.sh — shared MariaDB wait, `wp core install`, and
# summary logic.
#
# This is a LIBRARY, not an entry point: source it, don't execute it. It
# exists so the MariaDB wait loop, the exact `wp core install` invocation,
# and the closing summary each live in exactly one place, reused by:
#   - scripts/wp-setup.sh   (NER-211 task 1 — fresh bootstrap)
#   - scripts/wp-reset.sh   (NER-211 task 2 — `wp db reset --yes` then
#                            reinstall via the same guarded call)
#
# Contract for callers (set these up before sourcing):
#   - cwd is the repo root (so `wp` picks up ./wp-cli.yml).
#   - .env already exists and has been sourced (WP_HOME and DB_* creds come
#     from it — DB_* are needed by wait_for_mariadb).
#   - Before calling wp_core_install_guarded: MariaDB is reachable (call
#     wait_for_mariadb first) and the target database exists.
#
# WP_TITLE / WP_ADMIN_USER / WP_ADMIN_PASSWORD / WP_ADMIN_EMAIL fall back to
# dev-safe defaults below if not already set in the environment.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "scripts/wp-install.sh is a library — source it, don't execute it directly" >&2
  exit 1
fi

: "${WP_TITLE:=nix-wp-env}"
: "${WP_ADMIN_USER:=admin}"
: "${WP_ADMIN_PASSWORD:=password}"
: "${WP_ADMIN_EMAIL:=admin@example.com}"

# wait_for_mariadb — bounded wait for MariaDB to accept connections, using
# the DB_* creds from .env (must already be sourced). 30 tries x 1s, then a
# clear error on stderr and exit 1. Shared by scripts/wp-setup.sh (step 3)
# and scripts/wp-reset.sh so the wait logic lives in exactly one place.
wait_for_mariadb() {
  local db_host="${DB_HOST:-127.0.0.1}"
  local max_tries=30
  local tries=0
  until mysqladmin ping -h "$db_host" -u"$DB_USER" -p"$DB_PASSWORD" --silent >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max_tries" ]; then
      echo "ERROR: MariaDB not reachable at $db_host after ${max_tries}s — giving up" >&2
      exit 1
    fi
    sleep 1
  done
  echo "    MariaDB is reachable at $db_host"
}

# wp_core_install_guarded — idempotent `wp core install`.
#
# Safe to call whether WordPress is freshly bootstrapped (not installed yet)
# or after `wp db reset` (tables dropped, so `wp core is-installed` is false
# again) — both cases fall through to the same install call.
wp_core_install_guarded() {
  if wp core is-installed --quiet 2>/dev/null; then
    echo "    WordPress already installed — skipping wp core install"
  else
    wp core install \
      --url="$WP_HOME" \
      --title="$WP_TITLE" \
      --admin_user="$WP_ADMIN_USER" \
      --admin_password="$WP_ADMIN_PASSWORD" \
      --admin_email="$WP_ADMIN_EMAIL" \
      --skip-email
    echo "    WordPress installed"
  fi
}

# wp_print_summary — always prints the site URL, admin login URL, and admin
# username. Never prints the admin password in plaintext.
wp_print_summary() {
  echo ""
  echo "Site URL:        $WP_HOME"
  echo "Admin login URL: $WP_HOME/wp/wp-admin"
  echo "Admin username:  $WP_ADMIN_USER"
  echo "Admin password:  dev default — \$WP_ADMIN_PASSWORD (see README)"
  echo ""
}
