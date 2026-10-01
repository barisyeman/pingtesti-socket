# coturn (pingtesti) — köprü ağında çalışır, genel IP'yi açılışta kendisi bulur
FROM alpine:3.20
RUN apk add --no-cache coturn curl ca-certificates
COPY docker/coturn-entrypoint.sh /usr/local/bin/coturn-entrypoint.sh
RUN chmod +x /usr/local/bin/coturn-entrypoint.sh
EXPOSE 3478/udp 3478/tcp
ENTRYPOINT ["/usr/local/bin/coturn-entrypoint.sh"]
