#!/usr/bin/env bash
# =============================================================================
#  GACS Dashboard - One-Click Installer
#  Upstream : https://github.com/safrinnetwork/GACS-Dashboard
#  Stack    : Nginx + PHP-FPM 8.3+ + MariaDB + Composer 2 (no Docker)
#  Supports : Ubuntu 22.04/24.04+, Debian 12/13, AlmaLinux/Rocky/RHEL 8/9/10
#
#  Usage (as root):
#    bash install-gacs-dashboard.sh                     # HTTP on server IP
#    bash install-gacs-dashboard.sh --domain gacs.example.com --email you@example.com
#
#  Options:
#    --domain  <fqdn>     Server name; enables Let's Encrypt if --email is also set
#    --email   <addr>     Let's Encrypt registration e-mail
#    --tz      <zone>     PHP/app timezone          (default: Asia/Kolkata)
#    --admin-user <name>  Dashboard admin username  (default: admin)
#    --admin-pass <pass>  Dashboard admin password  (default: random)
#    --dir     <path>     Install path              (default: /var/www/gacs-dashboard)
#    --branch  <name>     Git branch                (default: main)
#
#  Re-running is safe: code is updated, configs regenerated, DB is never
#  re-imported and credentials are reused from /root/gacs-dashboard-credentials.txt
# =============================================================================
set -Eeuo pipefail

# ------------------------------ defaults -------------------------------------
REPO_URL="https://github.com/safrinnetwork/GACS-Dashboard.git"
BRANCH="main"
APP_DIR="/var/www/gacs-dashboard"
DOMAIN=""
LE_EMAIL=""
APP_TZ="Asia/Kolkata"
ADMIN_USER="admin"
ADMIN_PASS=""
ADMIN_PASS_GIVEN=0
DB_NAME="gacs"
DB_USER="gacs"
DB_PASS=""
DATA_DIR="/var/lib/gacs"
LOG_DIR="/var/log/gacs"
BACKUP_DIR="/var/backups/gacs"
CRED_FILE="/root/gacs-dashboard-credentials.txt"
INSTALL_LOG="/var/log/gacs-dashboard-install.log"

# ------------------------------ helpers --------------------------------------
c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_b='\033[1;34m'; c_n='\033[0m'
log()  { echo -e "${c_b}[*]${c_n} $*"; }
ok()   { echo -e "${c_g}[✓]${c_n} $*"; }
warn() { echo -e "${c_y}[!]${c_n} $*"; }
die()  { echo -e "${c_r}[✗]${c_n} $*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND  (full log: $INSTALL_LOG)"' ERR

randpw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

# Persist credentials immediately (root-only), keeping any previous admin entry
save_creds() {
  local url="${1:-}"
  {
    echo "# GACS Dashboard credentials - updated $(date -Is)"
    [[ -n "$url" ]] && echo "URL=${url}"
    echo "APP_DIR=${APP_DIR}"
    echo "DB_NAME=${DB_NAME}"
    echo "DB_USER=${DB_USER}"
    echo "DB_PASS=${DB_PASS}"
    if [[ -n "$ADMIN_PASS" ]]; then
      echo "ADMIN_USER=${ADMIN_USER}"
      echo "ADMIN_PASS=${ADMIN_PASS}"
    else
      grep -E '^ADMIN_(USER|PASS)=' "$CRED_FILE" 2>/dev/null || true
    fi
  } > "${CRED_FILE}.new"
  chmod 600 "${CRED_FILE}.new"
  mv -f "${CRED_FILE}.new" "$CRED_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="$2"; shift 2 ;;
    --email)      LE_EMAIL="$2"; shift 2 ;;
    --tz)         APP_TZ="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; ADMIN_PASS_GIVEN=1; shift 2 ;;
    --dir)        APP_DIR="${2%/}"; shift 2 ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,50}$ ]] || die "--admin-user: 3-50 chars [A-Za-z0-9_.-]"
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "--domain is not a valid hostname"
[[ -f "/usr/share/zoneinfo/$APP_TZ" ]] || die "--tz '$APP_TZ' is not a valid timezone"
if [[ $ADMIN_PASS_GIVEN -eq 1 && ${#ADMIN_PASS} -lt 8 ]]; then die "--admin-pass must be >= 8 chars"; fi

exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "==== GACS Dashboard install started $(date -Is) ===="

# ------------------------------ OS detection ---------------------------------
[[ -r /etc/os-release ]] || die "Cannot detect OS"
. /etc/os-release
OS_ID="${ID}"; OS_VER="${VERSION_ID%%.*}"; OS_LIKE="${ID_LIKE:-}"
case "$OS_ID" in
  ubuntu|debian) FAMILY="deb" ;;
  almalinux|rocky|rhel|centos|ol) FAMILY="rpm" ;;
  *)
    if   [[ "$OS_LIKE" == *debian* ]]; then FAMILY="deb"
    elif [[ "$OS_LIKE" == *rhel* ]]; then FAMILY="rpm"
    else die "Unsupported OS: $PRETTY_NAME"; fi ;;
esac
log "Detected: $PRETTY_NAME ($FAMILY)"

# ------------------------------ credentials ----------------------------------
if [[ -f "$CRED_FILE" ]]; then
  DB_PASS="$(grep -E '^DB_PASS=' "$CRED_FILE" | cut -d= -f2- || true)"
fi

# =============================================================================
#  1. Packages
# =============================================================================
install_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common \
                     apt-transport-https git unzip openssl cron logrotate

  PHP_VER=""
  for v in 8.3 8.4 8.5; do
    if apt-cache show "php${v}-fpm" >/dev/null 2>&1; then PHP_VER="$v"; break; fi
  done
  if [[ -z "$PHP_VER" ]]; then
    log "PHP 8.3 not in base repos - adding upstream PHP repository"
    if [[ "$OS_ID" == "ubuntu" ]]; then
      add-apt-repository -y ppa:ondrej/php
    else
      curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
      echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
    fi
    apt-get update -y
    PHP_VER="8.3"
  fi
  log "Using PHP $PHP_VER"

  apt-get install -y nginx mariadb-server mariadb-client \
    "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-common" "php${PHP_VER}-mysql" \
    "php${PHP_VER}-curl" "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
    "php${PHP_VER}-opcache" "php${PHP_VER}-intl"

  WEB_USER="www-data"; WEB_GROUP="www-data"
  PHP_BIN="/usr/bin/php${PHP_VER}"
  FPM_SVC="php${PHP_VER}-fpm"
  FPM_POOL_DIR="/etc/php/${PHP_VER}/fpm/pool.d"
  FPM_SOCK="/run/php/gacs-dashboard.sock"
  CRON_SVC="cron"
  DB_SVC="mariadb"
  rm -f /etc/nginx/sites-enabled/default
}

install_rpm() {
  local PM="dnf"; command -v dnf >/dev/null || PM="yum"
  $PM install -y epel-release 2>/dev/null || \
    $PM install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VER}.noarch.rpm"
  [[ "$OS_VER" -ge 9 ]] && { $PM config-manager --set-enabled crb 2>/dev/null || true; }
  [[ "$OS_VER" -eq 8 ]] && { $PM config-manager --set-enabled powertools 2>/dev/null || true; }

  if [[ "$OS_VER" -le 9 ]]; then
    # EL8/9: PHP 8.3 from Remi modular stream
    rpm -q remi-release >/dev/null 2>&1 || \
      $PM install -y "https://rpms.remirepo.net/enterprise/remi-release-${OS_VER}.rpm"
    $PM module reset -y php
    $PM module enable -y php:remi-8.3
  fi
  # EL10 ships PHP 8.3 in AppStream

  $PM install -y git unzip curl openssl cronie logrotate tar policycoreutils-python-utils \
                 nginx mariadb-server mariadb \
                 php-fpm php-cli php-common php-mysqlnd php-mbstring php-xml php-opcache \
                 php-process php-intl
  for p in php-sockets php-zip; do $PM install -y "$p" 2>/dev/null || true; done   # sockets may be built into php-common

  WEB_USER="nginx"; WEB_GROUP="nginx"
  PHP_BIN="/usr/bin/php"
  FPM_SVC="php-fpm"
  FPM_POOL_DIR="/etc/php-fpm.d"
  FPM_SOCK="/run/php-fpm/gacs-dashboard.sock"
  CRON_SVC="crond"
  DB_SVC="mariadb"
  PHP_VER="$($PHP_BIN -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  # Release :80 default_server from stock nginx.conf so our vhost can own it
  sed -i -E 's/(listen\s+\S*80)\s+default_server;/\1;/' /etc/nginx/nginx.conf
}

log "Installing system packages (Nginx, MariaDB, PHP 8.3+, tools)…"
if [[ "$FAMILY" == "deb" ]]; then install_deb; else install_rpm; fi

# Verify PHP version & extensions
$PHP_BIN -r 'exit(version_compare(PHP_VERSION,"8.3.0",">=")?0:1);' || die "PHP >= 8.3 required, got $($PHP_BIN -r 'echo PHP_VERSION;')"
for ext in mysqli json curl mbstring xml sockets openssl; do
  $PHP_BIN -m | grep -qi "^${ext}$" || die "PHP extension missing: $ext"
done
ok "PHP $($PHP_BIN -r 'echo PHP_VERSION;') with required extensions"

# =============================================================================
#  2. Composer (official installer, signature verified)
# =============================================================================
COMPOSER_BIN="$(command -v composer || true)"
COMPOSER_OK=0
if [[ -n "$COMPOSER_BIN" ]]; then
  CV="$(COMPOSER_ALLOW_SUPERUSER=1 $PHP_BIN "$COMPOSER_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -n "$CV" ]] && $PHP_BIN -r "exit(version_compare('$CV','2.8.0','>=')?0:1);" && COMPOSER_OK=1
fi
if [[ $COMPOSER_OK -eq 0 ]]; then
  log "Installing Composer 2 (latest)…"
  EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  ACTUAL_SIG="$($PHP_BIN -r "echo hash_file('sha384','/tmp/composer-setup.php');")"
  [[ "$EXPECTED_SIG" == "$ACTUAL_SIG" ]] || { rm -f /tmp/composer-setup.php; die "Composer installer signature mismatch"; }
  $PHP_BIN /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
  COMPOSER_BIN="/usr/local/bin/composer"
fi
ok "$(COMPOSER_ALLOW_SUPERUSER=1 $PHP_BIN "$COMPOSER_BIN" --version 2>/dev/null | head -1)"

# =============================================================================
#  3. Services
# =============================================================================
systemctl enable --now "$DB_SVC"
systemctl enable --now "$CRON_SVC"

# Basic MariaDB hardening (root uses unix_socket auth on fresh installs)
mysql -uroot <<'SQL'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
ok "MariaDB running"

# =============================================================================
#  4. Application code
# =============================================================================
log "Fetching GACS Dashboard ($BRANCH)…"
if [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]] && die "$APP_DIR exists and is not empty"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

# Upstream bug: "*/5" inside the /** */ header of cron scripts closes the comment
# early -> PHP parse error. Escape it so the cron jobs actually run.
for f in "$APP_DIR"/cron/*.php; do
  sed -i -E 's#^(\s*\*.*)\*/([0-9]+)#\1*\\/\2#' "$f"
done

log "Installing PHP dependencies with Composer…"
( cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 PATH="$(dirname "$PHP_BIN"):$PATH" \
    $PHP_BIN "$COMPOSER_BIN" install --no-dev --optimize-autoloader --no-interaction --no-progress )
[[ -f "$APP_DIR/vendor/autoload.php" ]] || die "Composer install failed"
ok "Composer dependencies installed"

# =============================================================================
#  5. Database
# =============================================================================
[[ -n "$DB_PASS" ]] || DB_PASS="$(randpw 24)"
log "Configuring database '$DB_NAME'…"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

FRESH_DB=0
TBL_COUNT="$(mysql -uroot -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='users';")"
if [[ "$TBL_COUNT" == "0" ]]; then
  log "Importing schema (database.sql)…"
  mysql -uroot "$DB_NAME" < "$APP_DIR/database.sql"
  FRESH_DB=1
  ok "Schema imported"
else
  ok "Existing schema detected - import skipped"
fi

# Replace default user1234/mostech on first install, or when --admin-pass is given
if [[ $FRESH_DB -eq 1 || $ADMIN_PASS_GIVEN -eq 1 ]]; then
  [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(randpw 16)"
  ADMIN_HASH="$($PHP_BIN -r 'echo password_hash($argv[1], PASSWORD_BCRYPT, ["cost"=>12]);' -- "$ADMIN_PASS")"
  mysql -uroot "$DB_NAME" <<SQL
UPDATE users SET username='${ADMIN_USER}', password='${ADMIN_HASH}' WHERE username IN ('user1234','${ADMIN_USER}');
INSERT INTO users (username, password)
  SELECT '${ADMIN_USER}', '${ADMIN_HASH}' FROM DUAL
  WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='${ADMIN_USER}');
SQL
  ok "Dashboard admin set: $ADMIN_USER"
fi
save_creds

# =============================================================================
#  6. App configuration
# =============================================================================
log "Writing application config…"
cat > "$APP_DIR/config/database.php" <<PHP
<?php
// Generated by install-gacs-dashboard.sh on $(date -Is)
define('DB_HOST', 'localhost');
define('DB_USER', '${DB_USER}');
define('DB_PASS', '${DB_PASS}');
define('DB_NAME', '${DB_NAME}');

function getDBConnection() {
    static \$conn = null;
    if (\$conn === null) {
        \$conn = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
        if (\$conn->connect_error) {
            die("Connection failed: " . \$conn->connect_error);
        }
        \$conn->set_charset("utf8mb4");
    }
    return \$conn;
}
PHP

cat > "$APP_DIR/config/config.php" <<PHP
<?php
// Generated by install-gacs-dashboard.sh on $(date -Is)
define('APP_NAME', 'GACS Dashboard');

// Auto-detect URL (app is installed at web root)
\$https = (!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off')
      || (\$_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
\$host  = \$_SERVER['HTTP_HOST'] ?? '${DOMAIN:-localhost}';
define('APP_URL', (\$https ? 'https' : 'http') . '://' . \$host);
define('ASSETS_URL', APP_URL . '/assets');

// Session
ini_set('session.cookie_httponly', 1);
ini_set('session.use_strict_mode', 1);
if (\$https) { ini_set('session.cookie_secure', 1); }
if (session_status() === PHP_SESSION_NONE) { @session_start(); }

date_default_timezone_set('${APP_TZ}');

error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);

require_once __DIR__ . '/../vendor/autoload.php';
require_once __DIR__ . '/database.php';
require_once __DIR__ . '/../lib/helpers.php';
PHP

# init.php is a web-based setup wizard with a hard-coded login - not needed, remove it
if [[ -f "$APP_DIR/init.php" ]]; then
  mkdir -p "$DATA_DIR/removed"
  mv -f "$APP_DIR/init.php" "$DATA_DIR/removed/init.php"
  ok "init.php removed from web root (kept in $DATA_DIR/removed/)"
fi

# =============================================================================
#  7. Permissions & writable paths
# =============================================================================
mkdir -p "$DATA_DIR/sessions" "$LOG_DIR" "$APP_DIR/logs" "$BACKUP_DIR"
touch /var/log/gacs-client.log
chown -R root:"$WEB_GROUP" "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 750 {} +
find "$APP_DIR" -type f -exec chmod 640 {} +
chmod 640 "$APP_DIR/config/database.php" "$APP_DIR/config/config.php"
chown -R "$WEB_USER":"$WEB_GROUP" "$APP_DIR/logs" "$DATA_DIR/sessions" "$LOG_DIR" /var/log/gacs-client.log
chmod 770 "$DATA_DIR/sessions" "$LOG_DIR" "$APP_DIR/logs"
chmod 700 "$BACKUP_DIR"

# =============================================================================
#  8. PHP-FPM pool
# =============================================================================
log "Configuring PHP-FPM pool…"
cat > "$FPM_POOL_DIR/gacs-dashboard.conf" <<EOF
[gacs-dashboard]
user = ${WEB_USER}
group = ${WEB_GROUP}
listen = ${FPM_SOCK}
listen.owner = ${WEB_USER}
listen.group = ${WEB_GROUP}
listen.mode = 0660

pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 500

php_admin_value[date.timezone] = ${APP_TZ}
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[upload_max_filesize] = 10M
php_admin_value[post_max_size] = 10M
php_admin_value[expose_php] = Off
php_admin_value[error_log] = ${LOG_DIR}/php-error.log
php_admin_flag[log_errors] = on
php_value[session.save_handler] = files
php_value[session.save_path] = ${DATA_DIR}/sessions
php_value[session.gc_maxlifetime] = 3600
EOF
mkdir -p "$(dirname "$FPM_SOCK")"
systemctl enable "$FPM_SVC"
systemctl restart "$FPM_SVC"
ok "PHP-FPM pool active ($FPM_SOCK)"

# =============================================================================
#  9. Nginx vhost  (replicates the upstream .htaccess rules)
# =============================================================================
log "Configuring Nginx…"
SERVER_NAME="${DOMAIN:-_}"
LISTEN_V6=""
[[ -s /proc/net/if_inet6 ]] && LISTEN_V6="listen [::]:80 default_server;"
cat > /etc/nginx/conf.d/gacs-dashboard.conf <<EOF
# GACS Dashboard - generated by install-gacs-dashboard.sh
server {
    listen 80 default_server;
    ${LISTEN_V6}
    server_name ${SERVER_NAME};

    root ${APP_DIR};
    index index.php;
    charset utf-8;

    client_max_body_size 10M;
    server_tokens off;

    access_log /var/log/nginx/gacs-dashboard.access.log;
    error_log  /var/log/nginx/gacs-dashboard.error.log;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Let's Encrypt challenges
    location ^~ /.well-known/acme-challenge/ { allow all; }

    # Block hidden files, internals and sensitive files
    location ~ /\.                                      { deny all; return 404; }
    location ~ ^/(config|lib|vendor|cron|logs|preview)/ { deny all; return 404; }
    location ~* \.(sql|sh|lock|md|env|example|log|bak)$ { deny all; return 404; }
    location = /composer.json                           { deny all; return 404; }
    location = /webhook/telegram_old.php                { deny all; return 404; }

    # Static assets
    location ~* \.(css|js|png|jpg|jpeg|gif|svg|ico|woff2?|ttf|eot|map)$ {
        expires 7d;
        access_log off;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS \$https if_not_empty;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }
}
EOF
nginx -t
systemctl enable nginx
systemctl restart nginx
ok "Nginx configured"

# =============================================================================
# 10. SELinux & firewall
# =============================================================================
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  log "Applying SELinux policy…"
  semanage fcontext -a -t httpd_sys_content_t    "${APP_DIR}(/.*)?"          2>/dev/null || semanage fcontext -m -t httpd_sys_content_t    "${APP_DIR}(/.*)?"
  semanage fcontext -a -t httpd_sys_rw_content_t "${APP_DIR}/logs(/.*)?"     2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "${APP_DIR}/logs(/.*)?"
  semanage fcontext -a -t httpd_sys_rw_content_t "${DATA_DIR}/sessions(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "${DATA_DIR}/sessions(/.*)?"
  semanage fcontext -a -t httpd_sys_rw_content_t "${LOG_DIR}(/.*)?"          2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "${LOG_DIR}(/.*)?"
  semanage fcontext -a -t httpd_sys_rw_content_t "/var/log/gacs-client.log"  2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "/var/log/gacs-client.log"
  restorecon -R "$APP_DIR" "$DATA_DIR" "$LOG_DIR" /var/log/gacs-client.log
  # Outbound calls: GenieACS NBI (7557), MikroTik API (8728), Telegram API
  setsebool -P httpd_can_network_connect 1
  ok "SELinux contexts and booleans set"
fi

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
  ok "firewalld: http/https opened"
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ok "ufw: 80/443 opened"
fi

# =============================================================================
# 11. Cron jobs, backup, log rotation
# =============================================================================
log "Installing cron jobs, backup and logrotate…"
cat > /usr/local/sbin/gacs-backup <<EOF
#!/usr/bin/env bash
# GACS Dashboard daily backup - generated by installer
set -euo pipefail
DEST="${BACKUP_DIR}"; KEEP_DAYS=7; TS=\$(date +%Y%m%d_%H%M%S)
umask 077
mysqldump --single-transaction --routines --triggers "${DB_NAME}" | gzip > "\$DEST/db_\$TS.sql.gz"
tar -czf "\$DEST/config_\$TS.tar.gz" -C "${APP_DIR}" config/config.php config/database.php
find "\$DEST" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) -mtime +\$KEEP_DAYS -delete
echo "[\$(date -Is)] backup ok: \$DEST/db_\$TS.sql.gz"
EOF
chmod 700 /usr/local/sbin/gacs-backup

cat > /etc/cron.d/gacs-dashboard <<EOF
# GACS Dashboard scheduled jobs - generated by installer
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# ONU/device status monitor + Telegram alerts
*/5 * * * * ${WEB_USER} ${PHP_BIN} ${APP_DIR}/cron/device-monitor.php >> ${LOG_DIR}/cron-device-monitor.log 2>&1
# Scheduled Telegram reports (script matches exact HH:MM, so it must run every minute)
* * * * *   ${WEB_USER} ${PHP_BIN} ${APP_DIR}/cron/send-scheduled-reports.php >> ${LOG_DIR}/cron-reports.log 2>&1
# Telegram webhook watchdog (no-op until a bot token is saved)
*/5 * * * * ${WEB_USER} ${PHP_BIN} ${APP_DIR}/cron/webhook-monitor.php >> ${LOG_DIR}/cron-webhook.log 2>&1
# Daily DB + config backup (02:30)
30 2 * * *  root /usr/local/sbin/gacs-backup >> ${LOG_DIR}/backup.log 2>&1
EOF
chmod 644 /etc/cron.d/gacs-dashboard

cat > /etc/logrotate.d/gacs-dashboard <<EOF
${LOG_DIR}/*.log ${APP_DIR}/logs/*.log {
    su ${WEB_USER} ${WEB_GROUP}
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${WEB_USER} ${WEB_GROUP}
}
/var/log/gacs-client.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${WEB_USER} ${WEB_GROUP}
}
EOF
systemctl restart "$CRON_SVC"
ok "Cron, backup and logrotate installed"

# =============================================================================
# 12. HTTPS (optional)
# =============================================================================
SCHEME="http"
if [[ -n "$DOMAIN" && -n "$LE_EMAIL" ]]; then
  log "Requesting Let's Encrypt certificate for $DOMAIN…"
  if [[ "$FAMILY" == "deb" ]]; then
    apt-get install -y certbot python3-certbot-nginx
  else
    ${PM:-dnf} install -y certbot python3-certbot-nginx
  fi
  if certbot --nginx -d "$DOMAIN" -m "$LE_EMAIL" --agree-tos -n --redirect; then
    SCHEME="https"; ok "HTTPS enabled (auto-renew via certbot timer)"
    systemctl enable --now certbot-renew.timer 2>/dev/null || systemctl enable --now certbot.timer 2>/dev/null || true
  else
    warn "Certificate request failed (DNS not pointing here / port 80 blocked?). Site stays on HTTP."
  fi
elif [[ -n "$DOMAIN" ]]; then
  warn "No --email given: skipped Let's Encrypt. Telegram webhooks require HTTPS."
fi

# =============================================================================
# 13. Health check & summary
# =============================================================================
HOST_ADDR="${DOMAIN:-$(hostname -I | awk '{print $1}')}"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN:-localhost}" http://127.0.0.1/login.php || true)"
if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then ok "Health check: /login.php -> HTTP $HTTP_CODE"
else warn "Health check returned HTTP $HTTP_CODE - see /var/log/nginx/gacs-dashboard.error.log and ${LOG_DIR}/php-error.log"; fi

save_creds "${SCHEME}://${HOST_ADDR}/"

trap - ERR
echo
echo -e "${c_g}=====================================================================${c_n}"
echo -e "${c_g}  GACS Dashboard installed${c_n}"
echo -e "${c_g}=====================================================================${c_n}"
echo "  URL            : ${SCHEME}://${HOST_ADDR}/"
[[ -n "$ADMIN_PASS" ]] && echo "  Admin login    : ${ADMIN_USER} / ${ADMIN_PASS}"
echo "  Credentials    : ${CRED_FILE}  (root only)"
echo "  PHP            : $($PHP_BIN -r 'echo PHP_VERSION;')  (pool: ${FPM_SVC}/gacs-dashboard)"
echo "  App path       : ${APP_DIR}"
echo "  Logs           : ${LOG_DIR}/  |  /var/log/nginx/gacs-dashboard.*.log"
echo "  Backups        : ${BACKUP_DIR}/  (daily 02:30, 7-day retention)"
echo
echo "  Next steps (in the dashboard → Configuration):"
echo "   1. ACS Config      : GenieACS host, NBI port 7557, user/pass → Test → Save"
echo "   2. MikroTik Config : router IP, API port 8728 (enable /ip service api) → Test → Save"
echo "   3. Bot Config      : Telegram bot token + chat ID (HTTPS required), then:"
echo "      curl \"https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://${DOMAIN:-your-domain}/webhook/telegram.php\""
echo
echo "  Update later     : re-run this script (DB and credentials are preserved)"
echo "==== finished $(date -Is) ===="
