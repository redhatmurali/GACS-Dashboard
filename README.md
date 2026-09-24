GACS Dashboard + GenieACS

One-click installation scripts for GenieACS and GACS Dashboard.

Repository: https://github.com/redhatmurali/GACS-Dashboard

Important: Download vs Install

These commands only download the scripts:

curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-genieacs.sh -o install-genieacs.sh
curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-gacs-dashboard.sh -o install-gacs-dashboard.sh

Then make them executable:

chmod +x install-genieacs.sh install-gacs-dashboard.sh

Then run the installer you need.

One-Click Download

Download install-genieacs.sh

Download install-gacs-dashboard.sh

Install GenieACS

Run as root:

curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-genieacs.sh -o install-genieacs.sh
chmod +x install-genieacs.sh
./install-genieacs.sh

With a hostname and password:

./install-genieacs.sh --acs-host acs.example.com --ui-pass 'StrongPassword'

GenieACS ports:

Service

Port

CWMP / TR-069

7547

NBI

7557

File Server

7567

Web UI

3000

Credentials:

/root/genieacs-credentials.txt

Log:

/var/log/genieacs-install.log

GenieACS CPU requirement

The installer requires an AVX-capable x86 CPU because supported MongoDB versions require AVX.

Check:

lscpu | grep -i avx

If avx is not shown, use an AVX-capable server/CPU. For a Proxmox/KVM VM, expose the host CPU and reboot.

Install GACS Dashboard

curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-gacs-dashboard.sh -o install-gacs-dashboard.sh
chmod +x install-gacs-dashboard.sh
./install-gacs-dashboard.sh

With domain and Let's Encrypt:

./install-gacs-dashboard.sh --domain gacs.example.com --email admin@example.com

The dashboard installer deploys Nginx, PHP 8.3+, PHP-FPM, MariaDB, Composer, the dashboard application, cron jobs, log rotation and daily backups.

Credentials:

/root/gacs-dashboard-credentials.txt

Logs:

/var/log/gacs-dashboard-install.log

Default application directory:

/var/www/gacs-dashboard

Default timezone:

Asia/Kolkata

Install Both on One Server

Install GenieACS first:

curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-genieacs.sh -o install-genieacs.sh
chmod +x install-genieacs.sh
./install-genieacs.sh

Then install the dashboard:

curl -fsSL https://raw.githubusercontent.com/redhatmurali/GACS-Dashboard/main/install-gacs-dashboard.sh -o install-gacs-dashboard.sh
chmod +x install-gacs-dashboard.sh
./install-gacs-dashboard.sh

When both are installed on the same server, the GenieACS installer can link the dashboard to the local GenieACS NBI when the dashboard database/credentials are available.

Supported Operating Systems

GenieACS

Ubuntu 20.04 / 22.04 / 24.04

Debian 11 / 12

AlmaLinux 8 / 9 / 10

Rocky Linux 8 / 9 / 10

RHEL 8 / 9 / 10

GACS Dashboard

Ubuntu 22.04 / 24.04+

Debian 12 / 13

AlmaLinux 8 / 9 / 10

Rocky Linux 8 / 9 / 10

RHEL 8 / 9 / 10

Service Checks

GenieACS:

systemctl status genieacs-cwmp
systemctl status genieacs-nbi
systemctl status genieacs-fs
systemctl status genieacs-ui
systemctl status mongod

Dashboard:

systemctl status nginx
systemctl status mariadb
systemctl status php*-fpm

Logs

journalctl -u genieacs-cwmp -f
journalctl -u genieacs-nbi -f
journalctl -u genieacs-fs -f
journalctl -u genieacs-ui -f
journalctl -u mongod -f

Dashboard:

tail -f /var/log/gacs-dashboard-install.log
tail -f /var/log/nginx/gacs-dashboard.error.log

Security

GenieACS NBI is localhost-only by default:

127.0.0.1:7557

Do not expose the NBI publicly unless required.

To intentionally expose it:

./install-genieacs.sh --nbi-public

Updating

The installers can be re-run:

./install-genieacs.sh

./install-gacs-dashboard.sh

Existing database data and credentials are preserved where applicable.

Repository

https://github.com/redhatmurali/GACS-Dashboard
