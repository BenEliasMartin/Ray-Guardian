FROM node:24-bookworm-slim
WORKDIR /app/server
COPY --chown=node:node server/ ./
RUN mkdir -p /data && chown node:node /data
USER node
ENV HOST=0.0.0.0 PORT=8787 DATA_PATH=/data/guardian.sqlite REPLAY_DIRECTORY=/replays
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s CMD node --input-type=module -e "const r=await fetch('http://127.0.0.1:8787/health');process.exit(r.ok?0:1)"
CMD ["node","index.mjs"]
