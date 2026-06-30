#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"         # Disable debugging
: "${PASSWORD:="root"}"   # Default password

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Display version number
info "Starting Proxmox Mail Gateway for Docker v$(</etc/version)..."
info "For support visit https://github.com/dockur/proxmox-mail"
echo ""

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# If missing timezone and localtime set them
set_timezone() {
  local zone="$1"

  if [ ! -f "/usr/share/zoneinfo/$zone" ]; then
    echo "Invalid timezone: $zone" >&2
    exit 18
  fi

  ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
  echo "$zone" > /etc/timezone
}

check_localtime() {
  if [ ! -e /etc/localtime ] && [ ! -L /etc/localtime ]; then
    return 1
  fi

  local target
  target="$(readlink -f /etc/localtime 2>/dev/null || true)"

  if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -s "$target" ]; then
    echo "Invalid TZ value." >&2
    exit 1
  fi

  return 0
}

if [ -n "${TZ:-}" ]; then
  set_timezone "$TZ"
elif ! check_localtime; then
  set_timezone "UTC"
fi

# Ensure directory permissions
user="www-data"

dir="/etc/pmg"
mkdir -p "$dir"
chmod 0750 "$dir" || :
chown "root:$user" "$dir" || :

dir="/etc/pmg/dkim"
mkdir -p "$dir"
chmod 0750 "$dir" || :
chown "root:$user" "$dir" || :

dir="/var/lib/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/var/spool/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/var/log/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/run/pmg"
mkdir -p "$dir"
chmod 0755 "$dir" || :
chown "root:root" "$dir" || :

# Generate keys
keys="/etc/pmg"

if [[ ! -f "$keys/pmg-authkey.key" ]]; then
  info "Generating authentication keys..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$keys/pmg-authkey.key" 2>/dev/null
  openssl pkey -in "$keys/pmg-authkey.key" -pubout -out "$keys/pmg-authkey.pub" 2>/dev/null
  chmod 640 "$keys/pmg-authkey.key"
  chmod 644 "$keys/pmg-authkey.pub"
  chown "root:$user" "$keys/pmg-authkey.key"
fi

if [[ ! -f "$keys/pmg-csrf.key" ]]; then
  info "Generating CSRF key..."
  openssl rand -base64 32 > "$keys/pmg-csrf.key"
  chmod 640 "$keys/pmg-csrf.key"
  chown "root:$user" "$keys/pmg-csrf.key"
fi

if [[ ! -f "$keys/pmg-api.pem" ]]; then
  info "Generating API certificate..."
  pmgconfig apicert
fi

if [[ ! -f "$keys/pmg-tls.pem" ]]; then
  info "Generating SMTP TLS certificate..."
  pmgconfig tlscert
fi

# Start PostgreSQL
echo "Starting PostgreSQL..."
/etc/init.d/postgresql start || ok=1

# Initialize PMG configuration and database
echo "Initializing PMG configuration..."
pmgconfig init || :
pmgconfig sync || :

echo "Initializing PMG database..."
pmgdb init || :

# Start rsyslog
echo "Starting rsyslog..."

cat >/etc/rsyslog.conf <<'EOF'
module(load="imuxsock")
input(type="imuxsock" Socket="/dev/log")
template(name="DockerFormat" type="string" string="%programname%:%msg%\n")

if $msg contains '#000' then stop
if $msg contains 'IORITY' then stop
if $msg contains 'F_LOG_TARGET' then stop
if $msg contains 'SYSLOG_IDENTIFIER' then stop

if $programname == 'runuser' then stop
if $programname == 'rsyslogd' and $msg contains '[origin software="rsyslogd"' then stop
*.* action(type="omfile" file="/var/log/system.log" template="DockerFormat")
EOF

rm -f /var/log/system.log
chmod 0644 /etc/rsyslog.conf

rsyslogd -n -iNONE -f /etc/rsyslog.conf &
RSYSLOG_PID=$!

while [ ! -S /dev/log ]; do
  sleep 0.2
done

mkdir -p /run/systemd/journal

ln -sf /dev/log /run/systemd/journal/syslog
ln -sf /dev/log /run/systemd/journal/socket

touch /var/log/system.log
tail -F /var/log/system.log &
TAIL_PID=$!

# Start Postfix
echo "Starting Postfix..."
/etc/init.d/postfix start || ok=1
read -r POSTFIX_PID < /var/spool/postfix/pid/master.pid

# Start supercronic
echo "Starting supercronic..."

cat >/docker.cron <<'EOF'
# Run PMG hourly maintenance
0 * * * * /usr/bin/pmg-hourly

# Send daily administrator system report
1 0 * * * /usr/bin/pmgreport --timespan yesterday --auto

# Send daily user spam report mails and purge quarantine
5 0 * * * /usr/bin/pmgqm purge; /usr/bin/pmgqm send --timespan yesterday

# Run PMG daily maintenance
30 3 * * * /usr/bin/pmg-daily
EOF

supercronic -quiet -no-reap /docker.cron &
CRON_PID=$!

_trap() {
  local func="$1"; shift
  local sig
  TRAP_PID=$BASHPID

  for sig; do
    trap "$func $sig" "$sig"
  done
}

cleanup() {

  [ -f /proxmox.end ] && return 0
  [[ $BASHPID != "$TRAP_PID" ]] && return 0

  touch /proxmox.end
  echo "Shutting down PMG services..."

  pmgproxy stop 2>/dev/null || :
  pmgdaemon stop 2>/dev/null || :
  pmg-smtp-filter stop 2>/dev/null || :
  pmgpolicy stop 2>/dev/null || :
  pmgmirror stop 2>/dev/null || :

  pids=(
    "$CRON_PID"
    "$POSTFIX_PID"
    "$RSYSLOG_PID"
    "$TAIL_PID"
  )

  # Send SIGTERM
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    kill -TERM "$pid" 2>/dev/null || :
  done

  /etc/init.d/postfix stop 2>/dev/null || :
  /etc/init.d/postgresql stop 2>/dev/null || :

  # Wait for processes
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    wait "$pid" 2>/dev/null || :
  done

  echo ""
  echo "Shutdown completed successfully."
  exit 0
}

# Init trap
rm -f /proxmox.end
_trap cleanup SIGTERM SIGINT

# Start PMG Services
echo "Starting pmgdaemon..."
pmgdaemon start

echo "Starting pmgproxy..."
pmgproxy start

echo "Starting pmg-smtp-filter..."
pmg-smtp-filter start

echo "Starting pmgpolicy..."
pmgpolicy start

echo "Starting pmgmirror..."
pmgmirror start || :

echo ""
info "------------------------------------------------------------------------------"
info ""
info ". Welcome to the Proxmox Mail Gateway v$(</etc/version). Connect your web browser to:"
info ""
info ".   https://127.0.0.1:${PORT:-8006}"
info ""
info "------------------------------------------------------------------------------"
info ""
echo ""

# Wait for processes
while true; do
  sleep 5

  pmgdaemon status >/dev/null 2>&1 || break
  pmgproxy status >/dev/null 2>&1 || break
  pmg-smtp-filter status >/dev/null 2>&1 || break
  pmgpolicy status >/dev/null 2>&1 || break
done

info "A PMG process exited unexpectedly. Shutting down..."
cleanup
