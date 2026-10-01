# pingtesti-socket — Docker / Dokploy / Coolify
# Konteynerde WebRTC eşine dışarıdan ulaşılamaz → TURN zorunlu:
#   TURN_HOST + (TURN_SECRET ya da TURN_USERNAME/TURN_PASSWORD) ortam değişkenlerini verin.
FROM node:22-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080 \
    HOST=0.0.0.0

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY src ./src

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

USER node
CMD ["node", "src/server.js"]
