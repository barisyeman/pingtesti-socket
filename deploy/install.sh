#!/usr/bin/env bash
# =============================================================================
#  pingtesti-socket — tek komutla sunucu kurulumu
#  Desteklenen: Ubuntu 22.04/24.04, Debian 12, AlmaLinux/Rocky/RHEL 8-9 — Plesk'li sunucular dahil
#
#  Mevcut sunucuyu bozmaz:
#    • Önce kontrol eder; çakışma varsa HİÇBİR ŞEYE DOKUNMADAN durur.
#    • Sadece eksik paketleri kurar (git dahil); kurulu paketleri güncellemez.
#    • Sistem Node.js'i yoksa/eskiyse ona dokunmaz — kendi Node'unu /opt/pingtesti-socket/.runtime'a kurar.
#    • Plesk varsa Plesk'in nginx/Apache ayarlarına dokunmaz: sertifika Plesk varsayılan sitesi üzerinden
#      (certbot webroot) alınır, servis SSL'i kendisi açar ve ayrı bir portta dinler (wss://alan:9443).
#    • Plesk yoksa: 80/443 boşsa ya da nginx'teyse nginx + certbot (wss://alan); başka bir şey varsa durur.
#
#  Kullanım:
#    curl -fsSL https://raw.githubusercontent.com/barisyeman/pingtesti-socket/main/deploy/install.sh \
#      | sudo bash -s -- --domain de.pingtesti.com --email info@pingtesti.com
#
#  Seçenekler:
#    --domain  ALAN     (zorunlu) Alan adı; DNS A kaydı bu makineyi göstermeli (Cloudflare proxy KAPALI)
#    --email   EPOSTA   Let's Encrypt bildirim adresi
#    --origins LİSTE    İzinli site kökenleri. Varsayılan: https://www.pingtesti.com,https://pingtesti.com
#    --name    AD       Sunucu adı (/health). Varsayılan: alan adı
#    --repo    URL      Varsayılan: https://github.com/barisyeman/pingtesti-socket.git
#    --branch  DAL      Varsayılan: main
#    --no-tls           Sertifika alma (test amaçlı)
#
#  Tekrar çalıştırmak güvenlidir: kodu günceller, mevcut TURN anahtarını korur.
# =============================================================================
set -euo pipefail

DOMAIN=""; EMAIL=""; NAME=""; NO_TLS=0
ORIGINS="https://www.pingtesti.com,https://pingtesti.com"
REPO="https://github.com/barisyeman/pingtesti-socket.git"; BRANCH="main"
APP_DIR="/opt/pingtesti-socket"; ENV_FILE="/etc/pingtesti-socket.env"; TLS_DIR="/etc/pingtesti-socket/tls"
RUNTIME="$APP_DIR/.runtime"; NODE_VERSION="22.12.0"
TURN_PORT=3478; MIN_PORT=49152; MAX_PORT=65535
MARK="# pingtesti-socket"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="$2"; shift 2 ;;
    --email)   EMAIL="$2"; shift 2 ;;
    --origins) ORIGINS="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --no-tls)  NO_TLS=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 1 ;;
  esac
done

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { echo; echo "${c_b}==> $*${c_0}"; }
ok()   { echo "${c_ok}✓${c_0} $*"; }
warn() { echo "${c_warn}!${c_0} $*"; }
die()  { echo "${c_err}✗ $*${c_0}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Root olarak çalıştırın (sudo)."
[[ -n "$DOMAIN" ]] || die "--domain zorunlu (ör. --domain de.pingtesti.com)."
[[ $NO_TLS -eq 1 || -n "$EMAIL" ]] || die "--email zorunlu (Let's Encrypt)."
NAME="${NAME:-$DOMAIN}"

# --- İşletim sistemi ailesi ----------------------------------------------------
if command -v apt-get >/dev/null; then
  OS=debian; export DEBIAN_FRONTEND=noninteractive
elif command -v dnf >/dev/null || command -v yum >/dev/null; then
  OS=rhel; PM=$(command -v dnf || command -v yum)
else
  die "Desteklenmeyen işletim sistemi (Debian/Ubuntu ya da AlmaLinux/Rocky/RHEL gerekli)."
fi
OS_NAME=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo "$OS")
PLESK=0; { [[ -d /usr/local/psa ]] || command -v plesk >/dev/null; } && PLESK=1

is_installed() { if [[ $OS == debian ]]; then dpkg -s "$1" >/dev/null 2>&1; else rpm -q "$1" >/dev/null 2>&1; fi; }
pkg_install() {
  (($#)) || return 0
  if [[ $OS == debian ]]; then apt-get update -qq; apt-get install -y -qq --no-upgrade "$@" >/dev/null
  else "$PM" install -y -q "$@" >/dev/null; fi
}
port_owner() { # $1=tcp|udp $2=port → süreç adı; dinleniyor ama ad okunamıyorsa "bilinmeyen"
  local flag line name; [[ $1 == udp ]] && flag=-lunp || flag=-ltnp
  line=$(ss -H $flag "sport = :$2" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 0
  name=$(grep -o 'users:(("[^"]*"' <<<"$line" | head -1 | sed 's/users:(("//; s/"$//')
  echo "${name:-bilinmeyen}"
}

# =============================================================================
step "Ön kontrol — $OS_NAME$([[ $PLESK -eq 1 ]] && echo ' + Plesk') (hiçbir şey değiştirilmeden)"
command -v ss >/dev/null || pkg_install iproute2 2>/dev/null || pkg_install iproute

# Mod: nginx (80/443 bizim) ya da direct (servis SSL'i kendisi açar, ayrı port — Plesk)
if [[ $PLESK -eq 1 ]]; then
  MODE=direct
  WEBROOT=/var/www/vhosts/default/htdocs
  [[ -d "$WEBROOT" ]] || die "Plesk varsayılan site klasörü bulunamadı ($WEBROOT)."
  ok "Plesk algılandı: Plesk'in nginx/Apache ayarlarına dokunulmayacak"
else
  MODE=nginx
  for p in 80 443; do
    owner=$(port_owner tcp $p)
    if [[ -n "$owner" && "$owner" != "nginx" ]]; then
      die "$p/tcp portunu '$owner' kullanıyor (Coolify/Traefik/Apache/Docker olabilir). Mevcut sistemi bozmamak için kurulum durduruldu."
    fi
  done
  ok "80/443: boş ya da nginx"
fi

TURN_CONF=/etc/turnserver.conf
[[ $OS == rhel || -d /etc/coturn ]] && TURN_CONF=/etc/coturn/turnserver.conf
owner=$(port_owner udp $TURN_PORT)
[[ -z "$owner" || "$owner" == "turnserver" ]] || die "$TURN_PORT/udp portunu '$owner' kullanıyor. Kurulum durduruldu."
if [[ -f $TURN_CONF ]] && grep -qvE '^\s*(#|$)' $TURN_CONF && ! grep -q "^# pingtesti" $TURN_CONF; then
  if [[ -n "$owner" ]] || systemctl is-active -q coturn 2>/dev/null; then
    die "Bu sunucuda başka bir coturn yapılandırması çalışıyor ($TURN_CONF). Ezmemek için kurulum durduruldu."
  fi
fi
ok "TURN ($TURN_PORT/udp): uygun"

# İç uygulama portu (nginx modunda) / dış SSL portu (direct modda)
EXISTING_PORT=$([[ -f $ENV_FILE ]] && grep -E '^PORT=' $ENV_FILE | cut -d= -f2 || true)
if [[ $MODE == direct ]]; then CANDIDATES="${EXISTING_PORT:-} 9443 10443 7443 2096 8843 9444"; else CANDIDATES="${EXISTING_PORT:-} $(seq 8080 8099)"; fi
PORT=""
for p in $CANDIDATES; do
  o=$(port_owner tcp "$p")
  if [[ -z "$o" || ( "$p" == "${EXISTING_PORT:-}" && "$o" == "node" ) ]]; then PORT=$p; break; fi
done
[[ -n "$PORT" ]] || die "Uygun boş port bulunamadı."
ok "servis portu: $PORT"

# =============================================================================
step "Eksik paketler"
need=()
for pkg in curl git ca-certificates openssl coturn; do is_installed "$pkg" || need+=("$pkg"); done
if [[ $OS == debian ]]; then is_installed xz-utils || need+=(xz-utils); else is_installed xz || need+=(xz); fi
if [[ $NO_TLS -eq 0 ]]; then is_installed certbot || need+=(certbot); fi
if [[ $MODE == nginx ]]; then
  is_installed nginx || need+=(nginx)
  if [[ $NO_TLS -eq 0 ]]; then is_installed python3-certbot-nginx || need+=(python3-certbot-nginx); fi
fi
if [[ $OS == rhel ]] && [[ " ${need[*]:-} " == *" coturn "* || " ${need[*]:-} " == *" certbot "* ]] && ! is_installed epel-release; then
  "$PM" install -y -q epel-release >/dev/null && ok "EPEL deposu eklendi"
fi
if ((${#need[@]})); then pkg_install "${need[@]}"; ok "kuruldu: ${need[*]}"; else ok "hepsi zaten kurulu"; fi
[[ " ${need[*]:-} " == *" coturn "* ]] && systemctl stop coturn 2>/dev/null || true

# =============================================================================
step "Node.js"
if command -v node >/dev/null && [[ $(node -p 'process.versions.node.split(".")[0]') -ge 20 ]]; then
  NODE_BIN=$(command -v node); ok "sistem node $(node -v) kullanılacak"
else
  case "$(uname -m)" in x86_64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) die "Desteklenmeyen mimari: $(uname -m)" ;; esac
  if [[ ! -x "$RUNTIME/bin/node" || "$("$RUNTIME/bin/node" -v 2>/dev/null)" != "v$NODE_VERSION" ]]; then
    mkdir -p "$RUNTIME"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$arch.tar.xz" | tar -xJ -C "$RUNTIME" --strip-components=1
  fi
  NODE_BIN="$RUNTIME/bin/node"; ok "özel node $("$NODE_BIN" -v) ($RUNTIME) — sistem Node'una dokunulmadı"
fi
NPM="$(dirname "$NODE_BIN")/npm"; [[ -x "$NPM" ]] || NPM=$(command -v npm)
export PATH="$(dirname "$NODE_BIN"):$PATH"

# =============================================================================
step "Uygulama ($APP_DIR)"
NOLOGIN=$(command -v nologin || echo /sbin/nologin)
id pingtesti >/dev/null 2>&1 || useradd --system --home-dir "$APP_DIR" --shell "$NOLOGIN" pingtesti
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
if [[ -f "$SCRIPT_DIR/../src/server.js" && "$(cd "$SCRIPT_DIR/.." && pwd)" != "$APP_DIR" ]]; then
  mkdir -p "$APP_DIR"
  (cd "$SCRIPT_DIR/.." && tar --exclude=node_modules --exclude=.runtime -cf - .) | tar -xf - -C "$APP_DIR"
  ok "yerel kopyadan kopyalandı"
elif [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch -q origin "$BRANCH" && git -C "$APP_DIR" reset -q --hard "origin/$BRANCH"
  ok "güncellendi ($(git -C "$APP_DIR" rev-parse --short HEAD))"
else
  tmp=$(mktemp -d); git clone -q --depth 1 -b "$BRANCH" "$REPO" "$tmp/src"
  mkdir -p "$APP_DIR"; (cd "$tmp/src" && tar -cf - .) | tar -xf - -C "$APP_DIR"; rm -rf "$tmp"
  ok "indirildi"
fi
cd "$APP_DIR"
if ! "$NPM" install --omit=dev --no-audit --no-fund --silent; then
  warn "Hazır derleme bulunamadı, kaynak koddan derleniyor…"
  if [[ $OS == debian ]]; then pkg_install build-essential cmake python3; else pkg_install gcc-c++ make cmake python3; fi
  "$NPM" install --omit=dev --no-audit --no-fund --build-from-source --silent
fi
chown -R pingtesti:pingtesti "$APP_DIR"
ok "bağımlılıklar kuruldu"

# =============================================================================
step "Ağ adresleri"
PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)
[[ -n "$PUBLIC_IP" ]] || die "Genel IPv4 adresi bulunamadı."
LOCAL_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' || true)
PRIMARY_LOCAL=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
ok "genel IP: $PUBLIC_IP"
DNS_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)
[[ -z "$DNS_IP" || "$DNS_IP" == "$PUBLIC_IP" ]] || warn "$DOMAIN → $DNS_IP çözülüyor, bu makine $PUBLIC_IP (Cloudflare proxy açıksa kapatın)."

# =============================================================================
TLS_ENV=""
if [[ $MODE == direct && $NO_TLS -eq 0 ]]; then
  step "Let's Encrypt (webroot: Plesk varsayılan sitesi — Plesk ayarlarına dokunulmaz)"
  CH="$WEBROOT/.well-known/acme-challenge"; mkdir -p "$CH"
  probe="pt-$(openssl rand -hex 6)"; echo "$probe" > "$CH/$probe"; chmod 644 "$CH/$probe"
  got=$(curl -fsS --max-time 10 "http://$DOMAIN/.well-known/acme-challenge/$probe" 2>/dev/null || true)
  rm -f "$CH/$probe"
  if [[ "$got" != "$probe" ]]; then
    die "http://$DOMAIN Plesk'in varsayılan sitesine ulaşmıyor. DNS A kaydı $DOMAIN → $PUBLIC_IP olmalı (Cloudflare proxy KAPALI) ve alan adı Plesk'e site olarak EKLENMEMİŞ olmalı."
  fi
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --keep-until-expiring -q
  mkdir -p "$TLS_DIR"
  HOOK=/etc/letsencrypt/renewal-hooks/deploy/pingtesti-socket.sh
  mkdir -p "$(dirname "$HOOK")"
  cat > "$HOOK" <<EOF
#!/bin/sh
$MARK — sertifika yenilenince servisin okuyabileceği yere kopyala (servis dosya değişince kendisi yükler)
[ -z "\$RENEWED_DOMAINS" ] || echo "\$RENEWED_DOMAINS" | grep -qw "$DOMAIN" || exit 0
install -m 640 -o root -g pingtesti /etc/letsencrypt/live/$DOMAIN/fullchain.pem $TLS_DIR/fullchain.pem
install -m 640 -o root -g pingtesti /etc/letsencrypt/live/$DOMAIN/privkey.pem $TLS_DIR/privkey.pem
EOF
  chmod 755 "$HOOK"; RENEWED_DOMAINS="$DOMAIN" "$HOOK"
  chown root:pingtesti "$TLS_DIR"; chmod 750 "$TLS_DIR"
  systemctl enable -q --now certbot-renew.timer 2>/dev/null || systemctl enable -q --now certbot.timer 2>/dev/null || true
  TLS_ENV="TLS_CERT=$TLS_DIR/fullchain.pem
TLS_KEY=$TLS_DIR/privkey.pem"
  ok "sertifika alındı, otomatik yenilenecek"
fi

# =============================================================================
step "Ortam dosyası ($ENV_FILE)"
TURN_SECRET=""
[[ -f "$ENV_FILE" ]] && TURN_SECRET=$(grep -E '^TURN_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)
[[ -n "$TURN_SECRET" ]] || TURN_SECRET=$(openssl rand -hex 32)
if [[ $MODE == direct ]]; then BIND=0.0.0.0; TRUST=0; else BIND=127.0.0.1; TRUST=1; fi
cat > "$ENV_FILE" <<EOF
$MARK — install.sh tarafından üretildi ($(date -u +%F))
PORT=$PORT
HOST=$BIND
SERVER_NAME=$NAME
TURN_SECRET=$TURN_SECRET
TURN_HOST=$PUBLIC_IP
TURN_PORT=$TURN_PORT
ICE_POLICY=relay
ALLOWED_ORIGINS=$ORIGINS
TRUST_PROXY=$TRUST
MAX_CONN_PER_IP=10
$TLS_ENV
EOF
chmod 640 "$ENV_FILE"; chown root:pingtesti "$ENV_FILE"
ok "TURN anahtarı hazır"

# =============================================================================
step "coturn (TURN/STUN) — $TURN_CONF"
mkdir -p "$(dirname "$TURN_CONF")"
[[ -f $TURN_CONF && ! -f $TURN_CONF.orig ]] && cp $TURN_CONF $TURN_CONF.orig
{
  echo "$MARK — install.sh tarafından üretildi"
  echo "listening-port=$TURN_PORT"
  echo "min-port=$MIN_PORT"
  echo "max-port=$MAX_PORT"
  if [[ -n "$PRIMARY_LOCAL" && "$PRIMARY_LOCAL" != "$PUBLIC_IP" ]]; then echo "external-ip=$PUBLIC_IP/$PRIMARY_LOCAL"; else echo "external-ip=$PUBLIC_IP"; fi
  echo "realm=$DOMAIN"
  echo "server-name=$DOMAIN"
  echo "fingerprint"
  echo "use-auth-secret"
  echo "static-auth-secret=$TURN_SECRET"
  echo "stale-nonce=600"
  echo "total-quota=400"
  echo "user-quota=4"
  echo "no-tcp-relay"
  echo "no-tls"
  echo "no-dtls"
  echo "no-cli"
  echo "no-multicast-peers"
  echo "no-software-attribute"
  echo "simple-log"
  echo "syslog"
  for r in 0.0.0.0-0.255.255.255 10.0.0.0-10.255.255.255 100.64.0.0-100.127.255.255 127.0.0.0-127.255.255.255 \
           169.254.0.0-169.254.255.255 172.16.0.0-172.31.255.255 192.0.0.0-192.0.0.255 192.168.0.0-192.168.255.255 \
           198.18.0.0-198.19.255.255 224.0.0.0-255.255.255.255 ::1 fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff \
           fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff; do echo "denied-peer-ip=$r"; done
  echo "allowed-peer-ip=$PUBLIC_IP"
  for ip in $LOCAL_IPS; do echo "allowed-peer-ip=$ip"; done
} > "$TURN_CONF"
getent group coturn >/dev/null && { chown root:coturn "$TURN_CONF"; chmod 640 "$TURN_CONF"; }
getent group turnserver >/dev/null && { chown root:turnserver "$TURN_CONF"; chmod 640 "$TURN_CONF"; }
[[ -f /etc/default/coturn ]] && sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
systemctl enable -q coturn
systemctl restart coturn
sleep 1
systemctl is-active -q coturn && ok "coturn çalışıyor (udp/$TURN_PORT)" || die "coturn başlamadı: journalctl -u coturn"

# =============================================================================
step "UDP tamponları"
for k in net.core.rmem_max net.core.wmem_max; do
  [[ $(sysctl -n $k) -ge 8388608 ]] || sysctl -q -w $k=8388608 >/dev/null
done
printf 'net.core.rmem_max=8388608\nnet.core.wmem_max=8388608\n' > /etc/sysctl.d/90-pingtesti.conf
ok "rmem/wmem ≥ 8 MB (yalnızca artırıldı)"

# =============================================================================
step "systemd servisi"
cat > /etc/systemd/system/pingtesti-socket.service <<EOF
[Unit]
Description=pingtesti-socket (WebRTC ping / hız testi sunucusu)
After=network-online.target coturn.service
Wants=network-online.target

[Service]
User=pingtesti
Group=pingtesti
EnvironmentFile=$ENV_FILE
WorkingDirectory=$APP_DIR
ExecStart=$NODE_BIN src/server.js
Restart=always
RestartSec=2
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q pingtesti-socket
systemctl restart pingtesti-socket
sleep 2
LOCAL_SCHEME=$([[ -n "$TLS_ENV" ]] && echo https || echo http)
curl -kfsS "$LOCAL_SCHEME://127.0.0.1:$PORT/health" >/dev/null && ok "pingtesti-socket çalışıyor ($LOCAL_SCHEME, port $PORT)" || die "Servis yanıt vermiyor: journalctl -u pingtesti-socket -n 50"

# =============================================================================
if [[ $MODE == nginx ]]; then
  step "nginx (yalnızca kendi site dosyası)"
  if [[ -d /etc/nginx/sites-available ]]; then SITE=/etc/nginx/sites-available/pingtesti-socket.conf; else SITE=/etc/nginx/conf.d/pingtesti-socket.conf; fi
  cat > "$SITE" <<EOF
$MARK
map \$http_upgrade \$pt_connection_upgrade { default upgrade; '' close; }
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$pt_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 2m;
    }
}
EOF
  [[ -d /etc/nginx/sites-enabled ]] && ln -sf "$SITE" /etc/nginx/sites-enabled/pingtesti-socket.conf
  if ! nginx -t -q 2>/dev/null; then
    rm -f "$SITE" /etc/nginx/sites-enabled/pingtesti-socket.conf
    die "nginx yapılandırma testi geçmedi; eklenen site geri alındı, mevcut nginx ayarlarına dokunulmadı."
  fi
  if command -v getenforce >/dev/null && [[ "$(getenforce)" == Enforcing ]]; then setsebool -P httpd_can_network_connect 1 || true; fi
  systemctl enable -q nginx
  if systemctl is-active -q nginx; then systemctl reload nginx; else systemctl start nginx; fi
  ok "http://$DOMAIN → 127.0.0.1:$PORT"
  if [[ $NO_TLS -eq 0 ]]; then
    step "Let's Encrypt"
    if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect --keep-until-expiring -q; then
      ok "https://$DOMAIN sertifikası kuruldu (otomatik yenilenir)"
    else
      warn "Sertifika alınamadı. DNS A kaydı $DOMAIN → $PUBLIC_IP olmalı ve 80/tcp açık olmalı. Sonra tekrar çalıştırın."
    fi
  fi
fi

# =============================================================================
step "Güvenlik duvarı"
if [[ $MODE == direct ]]; then OPEN_TCP="$TURN_PORT $PORT"; else OPEN_TCP="$TURN_PORT 80 443"; fi
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $OPEN_TCP; do ufw allow "$p/tcp" >/dev/null; done
  ufw allow $TURN_PORT/udp >/dev/null; ufw allow $MIN_PORT:$MAX_PORT/udp >/dev/null
  ok "ufw kuralları eklendi"
elif command -v firewall-cmd >/dev/null && systemctl is-active -q firewalld; then
  for p in $OPEN_TCP; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
  firewall-cmd -q --permanent --add-port=$TURN_PORT/udp --add-port=$MIN_PORT-$MAX_PORT/udp
  firewall-cmd -q --reload
  ok "firewalld kuralları eklendi"
else
  warn "Yerel güvenlik duvarı aktif değil."
fi
PORTS_TXT="$(echo $OPEN_TCP | tr ' ' ',')/tcp · $TURN_PORT/udp · $MIN_PORT-$MAX_PORT/udp"
[[ $PLESK -eq 1 ]] && warn "Plesk → Araçlar ve Ayarlar → Güvenlik Duvarı açıksa şu portlara izin verin: $PORTS_TXT"
warn "Bulut sağlayıcı güvenlik duvarında da açık olmalı: $PORTS_TXT"

# =============================================================================
step "Kontrol"
if [[ $MODE == direct ]]; then
  if [[ -n "$TLS_ENV" ]]; then WS_URL="wss://$DOMAIN:$PORT"; HEALTH="https://$DOMAIN:$PORT/health"; else WS_URL="ws://$DOMAIN:$PORT"; HEALTH="http://$DOMAIN:$PORT/health"; fi
else
  if [[ $NO_TLS -eq 1 ]]; then WS_URL="ws://$DOMAIN"; HEALTH="http://$DOMAIN/health"; else WS_URL="wss://$DOMAIN"; HEALTH="https://$DOMAIN/health"; fi
fi
if curl -fsS --max-time 8 "$HEALTH"; then echo; ok "dışarıdan erişilebilir"; else warn "$HEALTH dışarıdan yanıt vermedi (DNS/güvenlik duvarı?)"; fi

cat <<EOF

${c_b}Kurulum tamam.${c_0}
  Panelde (pingtesti.com/dashboard/servers) şu adresi ekleyin:  ${c_b}$WS_URL${c_0}
  Loglar:      journalctl -u pingtesti-socket -f   ·   journalctl -u coturn -f
  Güncelleme:  bu komutu tekrar çalıştırın.
EOF
