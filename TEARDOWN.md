# Teardown

**Do not run before a demo.** When you're done, tear everything down.

## 1. Delete the cluster
```sh
scripts/teardown.sh        # = kind delete cluster --name agent-gw (also stops port-forwards)
```
This removes everything inside the cluster: the gateway, Hermes, the MCP server, all Secrets (including the in-cluster copy of the OpenAI key) and NetworkPolicies.

## 2. Revoke the throwaway credentials
- **OpenAI key:** revoke it in the OpenAI dashboard (API keys). It was only ever in `.env` and the gateway's Secret.
- **Hermes API key** (`HERMES_API_SERVER_KEY` in `.env`): local-only, dies with the cluster.
- Then delete `.env` (`rm .env`). It's gitignored and was never committed.

## 3. Optional: reclaim disk
```sh
docker image rm nousresearch/hermes-agent:v0.22.5 mcp-everything:2.1.0 node:24-alpine
docker image prune
```
(Images pulled *inside* the kind node, e.g. `busybox:1.37` for probes, go away with the cluster container.)

## Rebuild from scratch
```sh
scripts/setup.sh && scripts/verify.sh all
```
Idempotent and unattended (needs `.env` with `OPENAI_API_KEY`; generates `HERMES_API_SERVER_KEY` if missing). Took 103 s on Nov 12 with images cached; plan for 5–8 min if the ~4 GB Hermes image has to be downloaded again.
