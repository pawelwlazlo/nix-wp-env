#!/usr/bin/env bash
# scripts/wp-install.sh — shared `wp core install` + summary logic.
#
# This is a LIBRARY, not an entry point: source it, don't execute it. It
# exists so the exact `wp core install` invocation and the closing summary
# live in exactly one place, reused by:
#   - scripts/wp-setup.sh   (NER-211 task 1 — fresh bootstrap)
#   - scripts/wp-reset.sh   (NER-211 task 2 — `wp db reset --yes` then
#                            reinstall via the same guarded call)
#
# Contract for callers (set these up before sourcing):
#   - cwd is the repo root (so `wp` picks up ./wp-cli.yml).
#   - .env already exists and has been sourced (WP_HOME comes from it).
#   - MariaDB is reachable and the target database exists.
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
