# MCP "everything" test server (reference server from modelcontextprotocol/servers).
# Built locally and loaded into kind instead of `npx` at pod start:
# pinned exact version, no npm download at runtime, starts offline.
# (Docker Hub's mcp/everything is a May 2025 build with old tool names.)
FROM node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5
RUN npm install -g @modelcontextprotocol/server-everything@2.1.0 && npm cache clean --force
ENV HOST=0.0.0.0 \
    PORT=3001
# numeric UID (= "node" user) so Kubernetes runAsNonRoot can verify it is not root
USER 1000
EXPOSE 3001
ENTRYPOINT ["mcp-server-everything"]
CMD ["streamableHttp"]
