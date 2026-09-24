#!/usr/bin/env bash
# =============================================================================
#  GenieACS - One-Click Installer (companion to install-gacs-dashboard.sh)
#  Stack    : Node.js 22 LTS + MongoDB 7.0/8.0 + GenieACS (npm) + systemd (no Docker)
#  Supports : Ubuntu 20.04/22.04/24.04, Debian 11/12, AlmaLinux/Rocky/RHEL 8/9/10
#
#  Usage (as root):
#    bash install-genieacs.sh
#    bash install-genieacs.sh --acs-host acs.example.com --ui-pass 'StrongPass#1'
#
#  Options:
#    --acs-host <ip|fqdn>  Address CPEs/ONUs use to reach this ACS  (default: primary IP)
#    --ui-user  <name>     GenieACS UI admin user                    (default: admin)
#    --ui-pass  <pass>     GenieACS UI admin password                (default: random)
#    --ui-port  <port>     GenieACS UI port                          (default: 3000)
#    --version  <x.y.z>    GenieACS version                          (default: 1.2.16)
#    --node     <major>    Node.js major version                     (default: 22)
#    --mongo    <ver>      MongoDB series: auto | 7.0 | 8.0          (default: auto)
#    --nbi-public          Expose NBI :7557 on all interfaces (NO AUTH - avoid!)
#    --no-params           Skip restoring the ISP virtual-parameter / UI preset pack
#    --keep-wan-remote     Keep upstream provision that enables WAN-side web/SSH/Telnet
#                          on Huawei/ZTE/FiberHome ONTs (disabled by default)
#
#  Ports: 7547 CWMP (CPEs) | 7567 FS (firmware) | 3000 UI | 7557 NBI (localhost only)
#  Re-running is safe: packages/units are refreshed, DB content and secrets are kept.
# =============================================================================
set -Eeuo pipefail

# ------------------------------ defaults -------------------------------------
GENIEACS_VER="1.2.16"            # >= 1.2.15 required (fixes RCE in /api/ping)
NODE_MAJOR="22"
MONGO_SERIES="auto"
ACS_HOST=""
UI_USER="admin"
UI_PASS=""
UI_PASS_GIVEN=0
UI_PORT="3000"
NBI_PUBLIC=0
RESTORE_PARAMS=1
KEEP_WAN_REMOTE=0

GACS_DIR="/opt/genieacs"
ENV_FILE="${GACS_DIR}/genieacs.env"
EXT_DIR="${GACS_DIR}/ext"
LOG_DIR="/var/log/genieacs"
CRED_FILE="/root/genieacs-credentials.txt"
DASH_CRED_FILE="/root/gacs-dashboard-credentials.txt"
INSTALL_LOG="/var/log/genieacs-install.log"
MONGO_DB="genieacs"

# ISP parameter pack (virtual parameters, UI layout, presets, provisions) used by GACS Dashboard
PARAM_REPO="https://github.com/safrinnetwork/GACS-Ubuntu-22.04.git"
PARAM_COMMIT="21eaf5fe318dcf28583df751ef7503fb552cae13"   # pinned, reviewed

# ------------------------------ helpers --------------------------------------
c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_b='\033[1;34m'; c_n='\033[0m'
log()  { echo -e "${c_b}[*]${c_n} $*"; }
ok()   { echo -e "${c_g}[✓]${c_n} $*"; }
warn() { echo -e "${c_y}[!]${c_n} $*"; }
die()  { echo -e "${c_r}[✗]${c_n} $*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND  (full log: $INSTALL_LOG)"' ERR
randpw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --acs-host)        ACS_HOST="$2"; shift 2 ;;
    --ui-user)         UI_USER="$2"; shift 2 ;;
    --ui-pass)         UI_PASS="$2"; UI_PASS_GIVEN=1; shift 2 ;;
    --ui-port)         UI_PORT="$2"; shift 2 ;;
    --version)         GENIEACS_VER="$2"; shift 2 ;;
    --node)            NODE_MAJOR="$2"; shift 2 ;;
    --mongo)           MONGO_SERIES="$2"; shift 2 ;;
    --nbi-public)      NBI_PUBLIC=1; shift ;;
    --no-params)       RESTORE_PARAMS=0; shift ;;
    --keep-wan-remote) KEEP_WAN_REMOTE=1; shift ;;
    -h|--help)         sed -n '2,29p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
[[ "$UI_USER" =~ ^[A-Za-z0-9_.-]{3,50}$ ]] || die "--ui-user: 3-50 chars [A-Za-z0-9_.-]"
[[ "$UI_PORT" =~ ^[0-9]{2,5}$ ]] || die "--ui-port must be numeric"
[[ "$NODE_MAJOR" =~ ^[0-9]{2}$ ]] || die "--node must be a major version, e.g. 22"
[[ "$MONGO_SERIES" =~ ^(auto|7\.0|8\.0)$ ]] || die "--mongo must be auto, 7.0 or 8.0"
[[ -z "$ACS_HOST" || "$ACS_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || die "--acs-host is not a valid host/IP"
if [[ $UI_PASS_GIVEN -eq 1 && ${#UI_PASS} -lt 8 ]]; then die "--ui-pass must be >= 8 chars"; fi
for p in 7547 7557 7567; do [[ "$UI_PORT" == "$p" ]] && die "--ui-port $p collides with a GenieACS service port"; done
[[ "$UI_PORT" == "80" || "$UI_PORT" == "443" ]] && die "--ui-port 80/443 is used by the GACS Dashboard (Nginx)"

exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "==== GenieACS install started $(date -Is) ===="

# ------------------------------ OS / CPU checks ------------------------------
[[ -r /etc/os-release ]] || die "Cannot detect OS"
. /etc/os-release
OS_ID="$ID"; OS_VER="${VERSION_ID%%.*}"; OS_CODENAME="${VERSION_CODENAME:-}"
case "$OS_ID" in
  ubuntu|debian) FAMILY="deb" ;;
  almalinux|rocky|rhel|centos|ol) FAMILY="rpm" ;;
  *) if [[ "${ID_LIKE:-}" == *debian* ]]; then FAMILY="deb"
     elif [[ "${ID_LIKE:-}" == *rhel* ]]; then FAMILY="rpm"
     else die "Unsupported OS: $PRETTY_NAME"; fi ;;
esac
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]] || die "Unsupported CPU architecture: $ARCH"
if [[ "$ARCH" == "x86_64" ]] && ! grep -qw avx /proc/cpuinfo; then
  die "CPU has no AVX - MongoDB 5.0+ will not run. On Proxmox/KVM set the VM CPU type to 'host' (or x86-64-v3) and reboot."
fi
log "Detected: $PRETTY_NAME ($FAMILY, $ARCH)"

# MongoDB series per platform (GenieACS 1.2 ships MongoDB driver 4.x: 7.0 preferred, 8.0 where 7.0 has no build)
MONGO_DIST=""   # repo codename (deb)
if [[ "$FAMILY" == "deb" ]]; then
  if [[ "$OS_ID" == "ubuntu" ]]; then
    case "$OS_CODENAME" in
      focal|jammy) AUTO_SERIES="7.0"; MONGO_DIST="$OS_CODENAME" ;;
      noble)       AUTO_SERIES="8.0"; MONGO_DIST="noble" ;;
      *)           AUTO_SERIES="8.0"; MONGO_DIST="noble"; warn "Ubuntu $OS_CODENAME not officially supported by MongoDB - using noble packages" ;;
    esac
  else
    case "$OS_CODENAME" in
      bullseye)    AUTO_SERIES="7.0"; MONGO_DIST="bullseye" ;;
      bookworm)    AUTO_SERIES="7.0"; MONGO_DIST="bookworm" ;;
      *)           AUTO_SERIES="8.0"; MONGO_DIST="bookworm"; warn "Debian $OS_CODENAME not officially supported by MongoDB - using bookworm packages" ;;
    esac
  fi
else
  AUTO_SERIES="7.0"
fi
[[ "$MONGO_SERIES" == "auto" ]] && MONGO_SERIES="$AUTO_SERIES"
if [[ "$OS_CODENAME" == "noble" && "$MONGO_SERIES" == "7.0" ]]; then die "MongoDB 7.0 has no Ubuntu 24.04 build - use --mongo 8.0"; fi
if [[ "$OS_CODENAME" == "bullseye" && "$MONGO_SERIES" == "8.0" ]]; then die "MongoDB 8.0 has no Debian 11 build - use --mongo 7.0"; fi
log "MongoDB series: $MONGO_SERIES | Node.js: $NODE_MAJOR.x | GenieACS: $GENIEACS_VER"

# =============================================================================
#  1. Repositories & packages
# =============================================================================
if [[ "$FAMILY" == "deb" ]]; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git openssl logrotate
  install -d -m 0755 /etc/apt/keyrings

  # Retire any pre-existing NodeSource / MongoDB source entries (.list or deb822 .sources,
  # any keyring path) - apt refuses duplicate repos with different Signed-By values.
  APT_BAK="/root/apt-sources-backup-$(date +%Y%m%d%H%M%S)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$APT_BAK"; mv -f "$f" "$APT_BAK/"
    warn "Moved conflicting apt source $f -> $APT_BAK/"
  done < <(grep -lsE 'deb\.nodesource\.com|repo\.mongodb\.org' /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)
  if grep -qsE '^[^#].*(deb\.nodesource\.com|repo\.mongodb\.org)' /etc/apt/sources.list; then
    cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
    sed -i -E '/deb\.nodesource\.com|repo\.mongodb\.org/ s/^([^#])/# \1/' /etc/apt/sources.list
    warn "Commented NodeSource/MongoDB lines in /etc/apt/sources.list"
  fi

  # Node.js (NodeSource)
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/nodesource

  # MongoDB (official)
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_SERIES}.asc" | gpg --dearmor --yes -o "/etc/apt/keyrings/mongodb-server-${MONGO_SERIES}.gpg"
  if [[ "$OS_ID" == "ubuntu" ]]; then
    MONGO_LINE="deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server-${MONGO_SERIES}.gpg] https://repo.mongodb.org/apt/ubuntu ${MONGO_DIST}/mongodb-org/${MONGO_SERIES} multiverse"
  else
    MONGO_LINE="deb [signed-by=/etc/apt/keyrings/mongodb-server-${MONGO_SERIES}.gpg] https://repo.mongodb.org/apt/debian ${MONGO_DIST}/mongodb-org/${MONGO_SERIES} main"
  fi
  echo "$MONGO_LINE" > "/etc/apt/sources.list.d/mongodb-org-${MONGO_SERIES}.list"

  apt-get update -y
  apt-get install -y nodejs mongodb-org
  FW_UFW=1
else
  PM="dnf"; command -v dnf >/dev/null || PM="yum"
  $PM install -y curl git openssl logrotate tar policycoreutils-python-utils
  # Node.js (NodeSource) - disable distro module stream first
  $PM module disable -y nodejs 2>/dev/null || true
  cat > /etc/yum.repos.d/nodesource-nodejs.repo <<EOF
[nodesource-nodejs]
name=Node.js ${NODE_MAJOR}.x (NodeSource)
baseurl=https://rpm.nodesource.com/pub_${NODE_MAJOR}.x/nodistro/nodejs/\$basearch
priority=9
enabled=1
gpgcheck=1
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
module_hotfixes=1
EOF
  # MongoDB (official)
  rm -f /etc/yum.repos.d/mongodb-org-*.repo
  cat > "/etc/yum.repos.d/mongodb-org-${MONGO_SERIES}.repo" <<EOF
[mongodb-org-${MONGO_SERIES}]
name=MongoDB ${MONGO_SERIES}
baseurl=https://repo.mongodb.org/yum/redhat/${OS_VER}/mongodb-org/${MONGO_SERIES}/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGO_SERIES}.asc
EOF
  $PM install -y nodejs mongodb-org
  FW_UFW=0
fi

NODE_V="$(node -v)"
[[ "${NODE_V#v}" =~ ^([0-9]+) ]] && [[ ${BASH_REMATCH[1]} -ge 18 ]] || die "Node.js >= 18 required, got $NODE_V"
command -v mongosh >/dev/null   || die "mongosh not installed"
command -v mongorestore >/dev/null || die "mongodb-database-tools not installed"
ok "Node.js $NODE_V, $(mongod --version | head -1)"

# =============================================================================
#  2. MongoDB service (localhost only)
# =============================================================================
if grep -qE '^\s*bindIp:' /etc/mongod.conf; then
  sed -i -E 's/^(\s*bindIp:).*/\1 127.0.0.1/' /etc/mongod.conf
fi
systemctl daemon-reload
systemctl enable mongod
systemctl restart mongod
log "Waiting for MongoDB…"
for _ in $(seq 1 60); do
  mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 2
done
mongosh --quiet --eval 'db.runCommand({ping:1}).ok' | grep -q 1 || die "MongoDB did not start (journalctl -u mongod)"
ok "MongoDB running on 127.0.0.1:27017"

# =============================================================================
#  3. GenieACS (npm)
# =============================================================================
log "Installing GenieACS $GENIEACS_VER from npm…"
npm install -g --no-fund --no-audit "genieacs@${GENIEACS_VER}"
NPM_BIN="$(npm prefix -g)/bin"
for s in cwmp nbi fs ui; do [[ -x "$NPM_BIN/genieacs-$s" ]] || die "genieacs-$s not found in $NPM_BIN"; done
ok "GenieACS $GENIEACS_VER installed ($NPM_BIN)"

id genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group --shell /usr/sbin/nologin genieacs
install -d -m 0750 -o genieacs -g genieacs "$GACS_DIR" "$EXT_DIR" "$LOG_DIR"

# ------------------------------ env file -------------------------------------
[[ -n "$ACS_HOST" ]] || ACS_HOST="$(hostname -I | awk '{print $1}')"
JWT_SECRET=""
[[ -f "$ENV_FILE" ]] && JWT_SECRET="$(grep -E '^GENIEACS_UI_JWT_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)"
[[ -n "$JWT_SECRET" ]] || JWT_SECRET="$(openssl rand -hex 64)"
NBI_IF="127.0.0.1"; [[ $NBI_PUBLIC -eq 1 ]] && NBI_IF="0.0.0.0"

cat > "$ENV_FILE" <<EOF
# GenieACS environment - generated by install-genieacs.sh $(date -Is)
GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1:27017/${MONGO_DB}
GENIEACS_EXT_DIR=${EXT_DIR}
GENIEACS_UI_JWT_SECRET=${JWT_SECRET}

GENIEACS_CWMP_INTERFACE=0.0.0.0
GENIEACS_CWMP_PORT=7547
GENIEACS_NBI_INTERFACE=${NBI_IF}
GENIEACS_NBI_PORT=7557
GENIEACS_FS_INTERFACE=0.0.0.0
GENIEACS_FS_PORT=7567
GENIEACS_FS_HOSTNAME=${ACS_HOST}
GENIEACS_UI_INTERFACE=0.0.0.0
GENIEACS_UI_PORT=${UI_PORT}

GENIEACS_CWMP_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=${LOG_DIR}/genieacs-debug.yaml
NODE_OPTIONS=--enable-source-maps
EOF
chown root:genieacs "$ENV_FILE"; chmod 0640 "$ENV_FILE"

# ------------------------------ systemd units --------------------------------
for s in cwmp nbi fs ui; do
  cat > "/etc/systemd/system/genieacs-${s}.service" <<EOF
[Unit]
Description=GenieACS ${s}
After=network-online.target mongod.service
Wants=network-online.target mongod.service

[Service]
User=genieacs
Group=genieacs
EnvironmentFile=${ENV_FILE}
ExecStart=${NPM_BIN}/genieacs-${s}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${LOG_DIR} ${EXT_DIR}

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload

cat > /etc/logrotate.d/genieacs <<EOF
${LOG_DIR}/*.log ${LOG_DIR}/*.yaml {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    missingok
    notifempty
    copytruncate
}
EOF

# =============================================================================
#  4. Parameter pack (virtual parameters, UI config, presets, provisions)
# =============================================================================
CPE_ACS_USER=""; CPE_ACS_PASS=""; CPE_CR_USER=""; CPE_CR_PASS=""
VP_COUNT="$(mongosh --quiet "$MONGO_DB" --eval 'db.virtualParameters.countDocuments({})')"
if [[ $RESTORE_PARAMS -eq 1 && "$VP_COUNT" == "0" ]]; then
  log "Restoring ISP parameter pack (pinned ${PARAM_COMMIT:0:7})…"
  TMPD="$(mktemp -d)"
  git clone -q "$PARAM_REPO" "$TMPD/p"
  git -C "$TMPD/p" checkout -q "$PARAM_COMMIT"
  for c in config virtualParameters presets provisions; do
    mongorestore --quiet --db "$MONGO_DB" --collection "$c" --drop "$TMPD/p/parameter/${c}.bson"
  done
  rm -rf "$TMPD"

  # Replace the hard-coded "msn/msn" CPE credentials in the 'inform' provision
  CPE_ACS_USER="acs$(randpw 6 | tr 'A-Z' 'a-z')"; CPE_ACS_PASS="$(randpw 20)"
  CPE_CR_USER="cr$(randpw 6 | tr 'A-Z' 'a-z')";   CPE_CR_PASS="$(randpw 20)"
  ACS_URL="http://${ACS_HOST}:7547" KEEP_WAN="$KEEP_WAN_REMOTE" \
  CPE_ACS_USER="$CPE_ACS_USER" CPE_ACS_PASS="$CPE_ACS_PASS" CPE_CR_USER="$CPE_CR_USER" CPE_CR_PASS="$CPE_CR_PASS" \
  mongosh --quiet "$MONGO_DB" --eval '
    const e = process.env;
    const inf = db.provisions.findOne({_id: "inform"});
    if (inf) {
      let s = inf.script
        .replace(/const url = "[^"]*";/,          `const url = "${e.ACS_URL}";`)
        .replace(/const AcsUser = "[^"]*";/,      `const AcsUser = "${e.CPE_ACS_USER}";`)
        .replace(/const AcsPass = "[^"]*";/,      `const AcsPass = "${e.CPE_ACS_PASS}";`)
        .replace(/let ConnReqUser = "[^"]*";/,    `let ConnReqUser = "${e.CPE_CR_USER}";`)
        .replace(/const ConnReqPass = "[^"]*";/,  `const ConnReqPass = "${e.CPE_CR_PASS}";`);
      db.provisions.updateOne({_id: "inform"}, {$set: {script: s}});
      print("inform provision: credentials replaced");
    }
    if (e.KEEP_WAN !== "1") {
      const d = db.provisions.findOne({_id: "default"});
      if (d) {
        const a = d.script.indexOf("//---------------------------- Remot Wan");
        const b = d.script.indexOf("//---------------------------- Update Parameter");
        if (a >= 0 && b > a) {
          db.provisions.updateOne({_id: "default"}, {$set: {script: d.script.slice(0, a) + d.script.slice(b)}});
          print("default provision: WAN-side remote access block removed");
        }
      }
    }'
  ok "Parameter pack restored (19 virtual parameters, UI layout, presets, provisions)"
elif [[ $RESTORE_PARAMS -eq 1 ]]; then
  ok "Virtual parameters already present - restore skipped"
fi

# =============================================================================
#  5. GenieACS UI admin user
# =============================================================================
USER_COUNT="$(mongosh --quiet "$MONGO_DB" --eval 'db.users.countDocuments({})')"
if [[ "$USER_COUNT" == "0" || $UI_PASS_GIVEN -eq 1 ]]; then
  [[ -n "$UI_PASS" ]] || UI_PASS="$(randpw 16)"
  # Same scheme as GenieACS: pbkdf2-sha512, 10000 iterations, 128-byte key, 64-byte hex salt
  UI_SALT="$(openssl rand -hex 64)"
  UI_HASH="$(P="$UI_PASS" S="$UI_SALT" node -e 'process.stdout.write(require("crypto").pbkdf2Sync(process.env.P, process.env.S, 10000, 128, "sha512").toString("hex"))')"
  U="$UI_USER" H="$UI_HASH" S="$UI_SALT" mongosh --quiet "$MONGO_DB" --eval '
    const e = process.env;
    db.users.replaceOne({_id: e.U}, {_id: e.U, password: e.H, salt: e.S, roles: "admin"}, {upsert: true});
    for (const r of ["devices","faults","files","presets","provisions","config","permissions","users","virtualParameters"]) {
      const id = `admin:${r}:3`;
      db.permissions.replaceOne({_id: id}, {_id: id, role: "admin", resource: r, access: 3, validate: "true"}, {upsert: true});
    }
    print("UI admin user set");'
  ok "GenieACS UI admin: $UI_USER"
fi

# =============================================================================
#  6. Start services
# =============================================================================
for s in cwmp nbi fs ui; do
  systemctl enable "genieacs-$s" >/dev/null 2>&1
  systemctl restart "genieacs-$s"
done
sleep 6
for s in mongod genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui; do
  if systemctl is-active --quiet "$s"; then ok "$s running"; else warn "$s NOT running (journalctl -u $s -n 50)"; fi
done

# =============================================================================
#  7. Firewall & SELinux
# =============================================================================
OPEN_PORTS=(7547 7567 "$UI_PORT")
[[ $NBI_PUBLIC -eq 1 ]] && OPEN_PORTS+=(7557)
if systemctl is-active --quiet firewalld; then
  for p in "${OPEN_PORTS[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null; done
  firewall-cmd --reload >/dev/null
  ok "firewalld: opened ${OPEN_PORTS[*]}"
elif [[ ${FW_UFW:-0} -eq 1 ]] && command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in "${OPEN_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null; done
  ok "ufw: opened ${OPEN_PORTS[*]}"
fi
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  warn "SELinux enforcing: MongoDB may log AVC denials for /sys/fs/cgroup (FTDC). Harmless; see https://github.com/mongodb/mongodb-selinux for a policy."
fi

# =============================================================================
#  8. Health checks
# =============================================================================
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" || true; }
NBI_CODE="$(code "http://127.0.0.1:7557/devices/?projection=_id&limit=1")"
UI_CODE="$(code "http://127.0.0.1:${UI_PORT}/")"
CWMP_CODE="$(code "http://127.0.0.1:7547/")"
[[ "$NBI_CODE" == "200" ]] && ok "NBI  :7557 -> $NBI_CODE" || warn "NBI  :7557 -> $NBI_CODE"
[[ "$UI_CODE" =~ ^(200|302)$ ]] && ok "UI   :${UI_PORT} -> $UI_CODE" || warn "UI   :${UI_PORT} -> $UI_CODE"
[[ "$CWMP_CODE" != "000" ]] && ok "CWMP :7547 -> $CWMP_CODE (listening)" || warn "CWMP :7547 not answering"

# =============================================================================
#  9. Link to GACS Dashboard (same server)
# =============================================================================
DASH_LINKED=0
if [[ "$NBI_CODE" == "200" && -f "$DASH_CRED_FILE" ]] && command -v mysql >/dev/null 2>&1; then
  DASH_DB="$(grep -E '^DB_NAME=' "$DASH_CRED_FILE" | cut -d= -f2- || true)"
  if [[ -n "$DASH_DB" ]]; then
    N="$(mysql -uroot -Nse "SELECT COUNT(*) FROM \`${DASH_DB}\`.genieacs_credentials;" 2>/dev/null || echo x)"
    if [[ "$N" == "0" ]]; then
      mysql -uroot "$DASH_DB" -e "INSERT INTO genieacs_credentials (host, port, username, password, role, is_connected, last_test) VALUES ('127.0.0.1', 7557, NULL, NULL, 'admin', 1, NOW());"
      DASH_LINKED=1; ok "GACS Dashboard linked to GenieACS NBI (127.0.0.1:7557)"
    elif [[ "$N" != "x" ]]; then
      ok "GACS Dashboard already has an ACS configured - left unchanged"
    fi
  fi
fi

# =============================================================================
# 10. Credentials & summary
# =============================================================================
OLD_CPE="$(grep -E '^CPE_' "$CRED_FILE" 2>/dev/null || true)"
OLD_UI="$(grep -E '^UI_(USER|PASS)=' "$CRED_FILE" 2>/dev/null || true)"
{
  echo "# GenieACS credentials - updated $(date -Is)"
  echo "UI_URL=http://${ACS_HOST}:${UI_PORT}/"
  if [[ -n "$UI_PASS" ]]; then echo "UI_USER=${UI_USER}"; echo "UI_PASS=${UI_PASS}"; else echo "$OLD_UI"; fi
  echo "ACS_URL=http://${ACS_HOST}:7547/"
  echo "NBI_URL=http://127.0.0.1:7557/"
  if [[ -n "$CPE_ACS_USER" ]]; then
    echo "CPE_ACS_USER=${CPE_ACS_USER}"; echo "CPE_ACS_PASS=${CPE_ACS_PASS}"
    echo "CPE_CONNREQ_USER=${CPE_CR_USER}"; echo "CPE_CONNREQ_PASS=${CPE_CR_PASS}"
  else echo "$OLD_CPE"; fi
} | sed '/^$/d' > "${CRED_FILE}.new"
chmod 600 "${CRED_FILE}.new"; mv -f "${CRED_FILE}.new" "$CRED_FILE"

trap - ERR
echo
echo -e "${c_g}=====================================================================${c_n}"
echo -e "${c_g}  GenieACS ${GENIEACS_VER} installed${c_n}"
echo -e "${c_g}=====================================================================${c_n}"
echo "  UI             : http://${ACS_HOST}:${UI_PORT}/"
[[ -n "$UI_PASS" ]] && echo "  UI login       : ${UI_USER} / ${UI_PASS}"
echo "  ACS URL (CPE)  : http://${ACS_HOST}:7547/     <- set this on ONUs / OLT TR-069 profile"
echo "  NBI (API)      : http://127.0.0.1:7557/   ($([[ $NBI_PUBLIC -eq 1 ]] && echo 'PUBLIC - no auth!' || echo 'localhost only'))"
echo "  Credentials    : ${CRED_FILE}  (root only)"
echo "  Config         : ${ENV_FILE}"
echo "  Logs           : ${LOG_DIR}/  |  journalctl -u genieacs-cwmp -f"
echo
if [[ $DASH_LINKED -eq 1 ]]; then
  echo "  GACS Dashboard : ACS Config already set to 127.0.0.1:7557 (no username/password)."
else
  echo "  GACS Dashboard : Configuration → ACS Config → Host 127.0.0.1, Port 7557,"
  echo "                   leave Username/Password empty → Test Connection → Save"
fi
echo "==== finished $(date -Is) ===="
