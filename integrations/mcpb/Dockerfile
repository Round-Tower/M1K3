# The M1K3 bridge in a container, for directories that introspect MCP servers in
# Docker (Glama). Build from the repository root:
#   docker build -f integrations/mcpb/Dockerfile -t m1k3-bridge .
#   docker run -i --rm m1k3-bridge
#
# What this is, honestly: the bridge relays to the M1K3 app on the SAME machine's
# loopback, and the app is a Mac app. In a container there is no M1K3 to reach, so the
# bridge answers the handshake and lists M1K3's tools from server/tools.json, and every
# call says to open M1K3. It is for introspection, not a way to run M1K3. To use M1K3,
# install the app: https://m1k3.app
#
# Signed: Kev + claude-opus-5.5, 2026-11-28, Confidence 0.85 (built and introspected
# locally: initialize, 19 tools from tools/list, a call that asks for the token).
# Prior: Unknown.
# Context: Kev, 2026-11-28, on Glama's quality grade for the awesome-mcp-servers listing:
# "Build it".
FROM node:22.23.4-alpine
WORKDIR /bridge
COPY integrations/mcpb/server/index.js integrations/mcpb/server/tools.json ./server/
USER node
ENTRYPOINT ["node", "server/index.js"]
