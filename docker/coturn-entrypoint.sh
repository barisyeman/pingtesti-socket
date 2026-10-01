#!/bin/sh
# Genel IP: TURN_EXTERNAL_IP verilmişse o, yoksa dış servislerden
IP="${TURN_EXTERNAL_IP:-}"
for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  [ -n "$IP" ] && break
  IP=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
done
LOCAL=$(hostname -i 2>/dev/null | awk '{print $1}')
if [ -z "$IP" ]; then
  echo "pingtesti-coturn: genel IP bulunamadı (TURN_EXTERNAL_IP verin)" >&2
  exit 1
fi
echo "pingtesti-coturn: genel IP $IP · konteyner IP $LOCAL · röle ${TURN_MIN_PORT:-49160}-${TURN_MAX_PORT:-49259}"
exec turnserver -n --log-file=stdout --simple-log \
  --listening-port=3478 --min-port="${TURN_MIN_PORT:-49160}" --max-port="${TURN_MAX_PORT:-49259}" \
  --external-ip="$IP${LOCAL:+/$LOCAL}" \
  --realm=pingtesti --fingerprint \
  --lt-cred-mech --user="${TURN_USERNAME:-pingtesti}:${TURN_PASSWORD:-pingtesti}" \
  --stale-nonce=600 --total-quota=200 \
  --no-cli --no-tls --no-dtls --no-tcp-relay --no-multicast-peers --no-software-attribute \
  --denied-peer-ip=0.0.0.0-0.255.255.255 --denied-peer-ip=10.0.0.0-10.255.255.255 \
  --denied-peer-ip=100.64.0.0-100.127.255.255 --denied-peer-ip=127.0.0.0-127.255.255.255 \
  --denied-peer-ip=169.254.0.0-169.254.255.255 --denied-peer-ip=192.168.0.0-192.168.255.255 \
  --denied-peer-ip=198.18.0.0-198.19.255.255 --denied-peer-ip=224.0.0.0-255.255.255.255
