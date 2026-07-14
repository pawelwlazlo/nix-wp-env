{ pkgs, config, ... }:

let
  # Single source of truth for the HTTP port (see NER-208 risks). Change it here
  # and both the Caddy vhost and the WP_PORT env var follow.
  httpPort = "8080";
in
{
  # ── Tooling ─────────────────────────────────────────────────────────────────
  # composer is provided by languages.php; wp-cli is added explicitly so the
  # shell has php + composer + wp on PATH.
  packages = [ pkgs.wp-cli ];

  # ── PHP 8.4 + PHP-FPM ───────────────────────────────────────────────────────
  languages.php = {
    enable = true;
    version = "8.4";

    # Extensions WordPress needs. (Some — curl, mbstring, dom, exif — are on by
    # default in the nixpkgs build; we list the full WP set explicitly so the
    # requirement is pinned and `php -m` is self-documenting.)
    extensions = [
      "mysqli"    # WordPress DB driver
      "gd"        # image manipulation / thumbnails
      "mbstring"  # multibyte string handling
      "curl"      # HTTP client (updates, REST)
      "dom"       # XML/HTML DOM
      "exif"      # image metadata
      "intl"      # internationalization
      "zip"       # plugin/theme zip install
    ];

    ini = ''
      memory_limit = 256M
      upload_max_filesize = 64M
      post_max_size = 64M
      max_execution_time = 300
    '';

    # FastCGI Process Manager pool that Caddy proxies PHP requests to.
    fpm.pools.web.settings = {
      "pm" = "dynamic";
      "pm.max_children" = 10;
      "pm.start_servers" = 2;
      "pm.min_spare_servers" = 1;
      "pm.max_spare_servers" = 5;
    };
  };

  # ── MariaDB ─────────────────────────────────────────────────────────────────
  # State lives under .devenv/state/mysql (devenv default). The `wordpress`
  # database and user are auto-created on first `devenv up`.
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    initialDatabases = [ { name = "wordpress"; } ];
    ensureUsers = [
      {
        name = "wordpress";
        password = "wordpress";
        ensurePermissions = { "wordpress.*" = "ALL PRIVILEGES"; };
      }
    ];
  };

  # ── Caddy ───────────────────────────────────────────────────────────────────
  # Plain HTTP for now; local HTTPS + wp.localhost land in NER-210. Serves the
  # Bedrock docroot in web/ (NER-209) and hands .php off to the PHP-FPM pool
  # socket.
  env.WP_PORT = httpPort;

  services.caddy = {
    enable = true;
    virtualHosts."http://localhost:${httpPort}" = {
      extraConfig = ''
        root * ${config.devenv.root}/web
        # Caddy unix-socket upstream syntax is `unix/` + absolute path, i.e.
        # `unix//tmp/.../web.sock` — NOT `unix://…` (that parses as a URL and
        # Caddy rejects the path component).
        php_fastcgi unix/${config.languages.php.fpm.pools.web.socket}
        file_server
      '';
    };
  };

  # The mysql module gates DB/user creation behind the `devenv:mysql:configure`
  # task, but `devenv up` only runs a task when a *process* depends on it. Make
  # Caddy wait on it so the `wordpress` database is auto-created on first `up`
  # (and the web server only starts once the DB is provisioned).
  processes.caddy.after = [ "devenv:mysql:configure" ];

  # ── Tasks ───────────────────────────────────────────────────────────────────
  # `wp:setup` (NER-211) idempotently bootstraps a cold checkout to a working,
  # installed WordPress site: composer install, .env + salts, wait for
  # MariaDB, ensure the DB exists, guarded `wp core install`. It depends on
  # `devenv:mysql:configure` (the same task Caddy already waits on above), so
  # it is downstream of the mysql process — plain `devenv up` does NOT run
  # it. Run it explicitly with `devenv up --mode after` (boots the stack and
  # then runs wp:setup + everything that depends on it) or on demand with
  # `devenv tasks run wp:setup`.
  tasks."wp:setup" = {
    exec = "${config.devenv.root}/scripts/wp-setup.sh";
    after = [ "devenv:mysql:configure" ];
  };

  # ── Shell greeting ──────────────────────────────────────────────────────────
  enterShell = ''
    echo ""
    echo "nix-wp-env — Bedrock WordPress devenv"
    echo "  $(php -v | head -n1)"
    echo "  $(composer --version 2>/dev/null | head -n1)"
    echo "  $(wp --version 2>/dev/null)"
    echo ""
    echo "Run 'devenv up', then open http://localhost:${httpPort}"
    echo ""
  '';
}
