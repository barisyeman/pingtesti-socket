# pingtesti-socket

pingtesti.com test sunucusu (v2). Her test lokasyonunda bir tane çalışır.

- **Ping / paket kaybı:** WebSocket sinyalleşme + WebRTC DataChannel (sırasız, yeniden gönderimsiz → UDP gibi). Sunucu her paketi yankılar; test sonunda aldığı paket id'lerini döner, böylece kayıp **yükleme / indirme** olarak ayrılır.
- **Hız testi:** `/speed` WebSocket uç noktası (indirme, yükleme, ping).
- **TURN:** coturn ile aynı makinede çalışır. Kısa ömürlü kullanıcı adı/şifre (TURN REST, HMAC-SHA1) her bağlantıda üretilip `hello` mesajıyla tarayıcıya verilir. Sitede veya kodda sabit TURN şifresi yoktur.
- **Sağlık:** `GET /health` → `{ok, version, clients, turn, ...}` (CORS açık).

## Sunucuya kurulum (tek komut)

Önce DNS'te `de.pingtesti.com` gibi bir A kaydını sunucunun IP'sine yönlendirin. Cloudflare kullanıyorsanız proxy'yi (turuncu bulut) bu kayıt için **kapalı** tutun. Sonra:

```bash
curl -fsSL https://raw.githubusercontent.com/barisyeman/pingtesti-socket/main/deploy/install.sh \
  | sudo bash -s -- --domain de.pingtesti.com --email info@pingtesti.com
```

Betik **mevcut sunucuyu bozmaz**: önce kontrol eder, 80/443'ü nginx dışında bir şey (Coolify, Traefik, Apache, Docker) kullanıyorsa ya da başka bir coturn ayarı varsa hiçbir şeye dokunmadan durur. Sadece eksik paketleri kurar (git dahil), kurulu paketleri güncellemez. Sistem Node.js'i yoksa veya eskiyse ona dokunmaz, kendi Node'unu `/opt/pingtesti-socket/.runtime` içine kurar. 8080 doluysa boş bir port seçer.

Betik şunları kurar ve ayarlar:

| Bileşen | Ayar |
|---|---|
| Node.js (sistemdeki ≥20 ya da özel 22) | `/opt/pingtesti-socket`, `pingtesti-socket.service` (systemd) |
| coturn | `use-auth-secret`, gizli anahtar otomatik üretilir; özel ağlara röle yasak, yalnızca bu makineye izinli |
| nginx | `wss://alan-adi` → `127.0.0.1:8080` |
| Let's Encrypt | sertifika + otomatik yenileme |
| Sistem | UDP tamponları, ufw kuralları (ufw aktifse) |

Bulut güvenlik duvarında (Hetzner, AWS vb.) şu portlar açık olmalı: `80,443/tcp`, `3478/udp+tcp`, `49152-65535/udp`.

Kurulumdan sonra panelde **Test Sunucuları** sayfasına `wss://de.pingtesti.com` adresini ekleyin. Panelin **Otomatik sunucu kurulumu** formu (IP + SSH kullanıcı/şifre) bu adımların hepsini kendisi yapar.

**Güncelleme:** aynı komutu tekrar çalıştırın. Kod güncellenir, TURN anahtarı korunur.

## Docker / Coolify ile çalıştırma

Konteyner içindeki WebRTC eşinin adresine dışarıdan ulaşılamaz. Bu yüzden **TURN zorunludur**: hem tarayıcı hem sunucu, makinedeki coturn üzerinden röle yapar. Coolify → Environment Variables:

```
TURN_HOST=turn.example.com               # coturn'un çalıştığı makine (alan adı ya da IP)
TURN_USERNAME=kullanici                  # turnserver.conf → user=kullanici:sifre
TURN_PASSWORD=sifre
# ya da coturn use-auth-secret kullanıyorsa: TURN_SECRET=...
ALLOWED_ORIGINS=https://www.pingtesti.com,https://pingtesti.com
```

`/health` çıktısında `"turn": true` görünmelidir.

## Yerel geliştirme

```bash
npm install
cp .env.example .env      # TURN_SECRET boş → doğrudan bağlantı
npm start                 # ws://127.0.0.1:8080
npm test                  # uçtan uca duman testi (ping + hız)
TARGET=wss://de.pingtesti.com npm test   # kurulu bir sunucuyu dene
```

## Protokol

```
WS /            S→C {type:'hello', v:2, iceServers, iceTransportPolicy, limits:{maxRate,maxDuration,maxSize}}
                C→S {type:'offer', sdp}           S→C {type:'answer', sdp}
                C↔S {type:'ice', ice:{candidate, sdpMid, sdpMLineIndex}}
  DataChannel   C→S {"id":N,"time":T,"data":"…"}  S→C {"id":N,"time":T}
                C→S {type:'done'}                 S→C {type:'results', list:[id…], receivedCount}

WS /speed       S→C {type:'hello', speed:true}
                C→S {type:'ping', t}              S→C {type:'pong', t}
                C→S {type:'download', seconds}    S→C ikili parçalar… {type:'download_end', bytes}
                C→S {type:'upload', seconds}      S→C {type:'upload_ready'} · {type:'upload_progress', bytes, ms} · {type:'upload_end', bytes, ms}
```

v1 sunucular `hello` göndermez. Site bu durumda paneldeki "eski TURN" bilgisine düşer, yani eski sunucular kurulum yapılana kadar çalışmaya devam eder.
