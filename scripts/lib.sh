#!/usr/bin/env bash
# Shared helpers for setup.sh / verify.sh / demo.sh. Source it, don't run it.
#   . "$(dirname "$0")/lib.sh"

# BASH_SOURCE is empty when sourced from zsh; zsh puts the sourced file in $0 instead.
_LIB_SRC="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$_LIB_SRC")/.." && pwd)"
CLUSTER_NAME="agent-gw"
GW_NS="agentgateway-system"
GW_NAME="agentgateway-proxy"
GW_LOCAL_PORT="${GW_LOCAL_PORT:-8080}"
GW_URL="http://localhost:${GW_LOCAL_PORT}"

# ---------- pretty output ----------
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

PASS_COUNT=0
FAIL_COUNT=0

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info()    { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()    { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

# pass "<check id + description>" "<evidence>"
pass() { PASS_COUNT=$((PASS_COUNT+1)); printf '%sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"; [ -n "${2:-}" ] && info "evidence: $2"; return 0; }
# fail "<check id + description>" "<evidence>"
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf '%sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"; [ -n "${2:-}" ] && info "evidence: $2"; return 0; }

# Print totals; exit non-zero if anything failed.
summary() {
  printf '\n%sResult: %d passed, %d failed%s\n' "$C_BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$C_RESET"
  [ "$FAIL_COUNT" -eq 0 ]
}

die() { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ---------- secrets ----------
# Load .env into the environment without ever printing it.
load_env() {
  if [ -f "$REPO_ROOT/.env" ]; then
    set -a; . "$REPO_ROOT/.env"; set +a
  fi
}

# Make sure OPENAI_API_KEY is present. Checks length only, never prints the value.
require_key() {
  load_env
  [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY not set (put it in .env)"
  [ "${#OPENAI_API_KEY}" -ge 20 ] || die "OPENAI_API_KEY looks too short (${#OPENAI_API_KEY} chars)"
}

# ---------- port-forwards (auto-cleaned on exit) ----------
PF_PIDS=()
# Always returns 0: an EXIT trap's status can leak into the script's exit code.
pf_cleanup() { local p; for p in "${PF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -f "${LLM_BODY_FILE:-}" "${LOG_MARK_FILE:-}" "${AGENT_BODY_FILE:-}"; return 0; }
trap pf_cleanup EXIT

# port_forward <namespace> <resource> <local:remote>
# Starts kubectl port-forward in the background and waits until the local port accepts connections.
port_forward() {
  local ns="$1" res="$2" ports="$3" local_port="${3%%:*}"
  # Reuse an existing listener only if it really answers HTTP. A kubectl port-forward dies when its
  # target pod is replaced (restart, rollout, scale) but can leave a dead listener behind.
  if nc -z localhost "$local_port" 2>/dev/null; then
    local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$local_port/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != "000" ] && return 0
    warn "stale listener on :$local_port (no HTTP answer); restarting the port-forward"
    lsof -ti "tcp:$local_port" -sTCP:LISTEN -c kubectl 2>/dev/null | xargs kill 2>/dev/null; sleep 1
  fi
  kubectl port-forward -n "$ns" "$res" "$ports" >/dev/null 2>&1 &
  PF_PIDS+=($!); disown $! 2>/dev/null   # disown: no "Terminated" noise when we kill it
  for _ in $(seq 1 30); do
    nc -z localhost "$local_port" 2>/dev/null && return 0
    sleep 0.5
  done
  warn "port-forward $ns/$res $ports did not come up"
  return 1
}

# Port-forward the gateway Service to localhost:$GW_LOCAL_PORT.
gw_forward() { port_forward "$GW_NS" "svc/$GW_NAME" "${GW_LOCAL_PORT}:80"; }

# ---------- LLM via gateway ----------
# Clients use "openai/<model>"; the gateway strips the prefix before calling OpenAI.
LLM_MODEL="${LLM_MODEL:-openai/gpt-4.1-mini-2025-04-14}"   # pinned snapshot; fallback openai/gpt-4o-mini (DEMO.md)
LLM_BODY_FILE="${TMPDIR:-/tmp}/agw-llm-body.$$"

# gw_chat "<prompt>" [extra curl args...]
# One fresh single-message request (no history). Prints the HTTP status;
# the response body is left in $LLM_BODY_FILE.
gw_chat() {
  local prompt="$1"; shift
  local payload
  payload=$(jq -n --arg m "$LLM_MODEL" --arg p "$prompt" \
    --argjson t "${GW_MAX_TOKENS:-60}" \
    '{model:$m, max_tokens:$t, temperature:0, messages:[{role:"user", content:$p}]}')
  log_mark
  curl -s -o "$LLM_BODY_FILE" -w '%{http_code}' --max-time 60 \
    -H 'Content-Type: application/json' "$@" \
    -d "$payload" "$GW_URL/v1/chat/completions"
}
# Text of the assistant reply from the last gw_chat call.
gw_reply() { jq -r '.choices[0].message.content // empty' "$LLM_BODY_FILE" 2>/dev/null; }

# Proxy access-log lines from ALL proxy replicas (label selector, not deploy/: that reads one pod).
# --tail=-1 is required: with a selector kubectl defaults to the last 10 lines per pod.
GW_PROXY_SELECTOR="app.kubernetes.io/name=$GW_NAME"
gw_logs() { kubectl logs -n "$GW_NS" -l "$GW_PROXY_SELECTOR" --tail=-1 --max-log-requests=10 --since="${1:-120}s" 2>/dev/null; }

# Each request records its start time; the gw_last_* lookups only read log lines after it,
# so a leftover line from an earlier run can never satisfy a check.
LOG_MARK_FILE="${TMPDIR:-/tmp}/agw-log-mark.$$"
log_mark() { date -u +%Y-%m-%dT%H:%M:%SZ > "$LOG_MARK_FILE"; }
gw_logs_since_mark() {
  local mark; mark=$(cat "$LOG_MARK_FILE" 2>/dev/null) || { gw_logs 60; return; }
  kubectl logs -n "$GW_NS" -l "$GW_PROXY_SELECTOR" --tail=-1 --max-log-requests=10 --since-time="$mark" 2>/dev/null
}

# Last LLM access-log line (the request we just made; verify runs sequentially).
# Log lines can lag (busy node, e.g. right after a restart): poll up to ~6 s, never a fixed sleep.
gw_last_llm_log() {
  local i line
  for i in 1 2 3 4 5 6; do
    sleep 1; line=$(gw_logs_since_mark | grep 'http.path=/v1/chat/completions' | grep 'src.addr=127.0.0.1:' | tail -1)
    [ -n "$line" ] && break
  done; echo "$line"
}

# Pull the readable guardrail fields out of an access-log line.
guard_fields() { echo "$1" | grep -oE 'http.status=[0-9]+|agw.ai.guardrails=\[[^]]*\]|reason=[A-Za-z]+|gen_ai.usage.input_tokens=[0-9]+' | tr '\n' ' '; }

# Test inputs shared by verify.sh and demo.sh. Fake values only.
DEMO_EMAIL="jane.doe@example.com"
DEMO_FAKE_OPENAI_KEY="sk-demoFAKE1234567890abcdefghijklmnop"   # fake, matches OpenAI key shape
DEMO_FAKE_AWS_KEY="AKIAIOSFODNN7EXAMPLE"                        # AWS's own documentation example key
GUARD_MSG="Blocked by platform policy: request contains a secret/credential."

# ---------- MCP via gateway ----------
MCP_URL="$GW_URL/mcp"
INSPECTOR="@modelcontextprotocol/inspector@0.21.2"   # pinned MCP Inspector CLI
# mcp_cli <inspector args...>   e.g. mcp_cli --method tools/list
mcp_cli() { log_mark; npx -y "$INSPECTOR" --cli "$MCP_URL" --transport http "$@" 2>&1; }
# Names of the tools the gateway exposes, space-separated.
mcp_tool_names() { mcp_cli --method tools/list | jq -r '.tools[].name' 2>/dev/null | tr '\n' ' '; }
# Readable MCP fields from an access-log line (drops the long session id).
mcp_fields() { echo "$1" | grep -oE 'http.status=[0-9]+|mcp\.(method\.name|target)=[^ ]+|gen_ai\.tool\.name=[^ ]+|reason=[A-Za-z]+|error[a-z_.]*=("[^"]*"|[^ ]+)' | tr '\n' ' '; }
# Last MCP access-log line from our own (port-forwarded) traffic.
gw_last_mcp_log() {
  local i line
  for i in 1 2 3 4 5 6; do
    sleep 1; line=$(gw_logs_since_mark | grep 'http.path=/mcp' | grep 'src.addr=127.0.0.1:' | grep -F "$1" | tail -1)
    [ -n "$line" ] && break
  done; echo "$line"
}
FAKE_SECRET_VALUE="hunter2-demo"     # the fake credential in the MCP server's env (must never appear)

# ---------- Hermes agent (API server) ----------
AGENT_NS="agents"
AGENT_NAME="hermes"
AGENT_LOCAL_PORT="${AGENT_LOCAL_PORT:-8642}"
AGENT_URL="http://localhost:${AGENT_LOCAL_PORT}"
AGENT_BODY_FILE="${TMPDIR:-/tmp}/hermes-body.$$"
agent_forward() { port_forward "$AGENT_NS" "svc/$AGENT_NAME" "${AGENT_LOCAL_PORT}:8642"; }
agent_pod_ip() { kubectl get pod -n "$AGENT_NS" -l "app=$AGENT_NAME" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null; }

# agent_ask "<scene>" "<prompt>"  -> prints the reply text (or "ERROR: <message>").
# Every call is a NEW Hermes session (unique X-Hermes-Session-Id): without it Hermes derives the
# session from the first message, so a repeated demo prompt would inherit old history.
# HERMES_API_SERVER_KEY comes from .env (never printed).
agent_ask() {
  load_env
  local sid="verify-$1-$(date +%s)-$RANDOM"
  log_mark
  rm -f "$AGENT_BODY_FILE"   # never let a failed request leave the previous scene's reply behind
  local code
  code=$(curl -s -o "$AGENT_BODY_FILE" -w '%{http_code}' --max-time "${AGENT_TIMEOUT:-90}" "$AGENT_URL/v1/chat/completions" \
    -H "Authorization: Bearer ${HERMES_API_SERVER_KEY:-}" -H 'Content-Type: application/json' \
    -H "X-Hermes-Session-Id: $sid" \
    -d "$(jq -n --arg p "$2" '{model:"hermes-agent", messages:[{role:"user", content:$p}]}')")
  [ "$code" = "200" ] || { echo "ERROR: HTTP ${code:-none} $(jq -r '.error.message // empty' "$AGENT_BODY_FILE" 2>/dev/null)"; return; }
  jq -r '.choices[0].message.content // ("ERROR: " + (.error.message // "no response"))' "$AGENT_BODY_FILE" 2>/dev/null \
    || echo "ERROR: no/invalid response"
}
# Gateway log lines (since the last request) that came FROM the agent pod.
# (polls until at least one LLM line from the agent is logged; the agent's last call is always an LLM call)
gw_logs_from_agent() {
  local ip i out; ip=$(agent_pod_ip)
  for i in 1 2 3 4 5 6; do
    sleep 1; out=$(gw_logs_since_mark | grep -F "src.addr=${ip}:")
    grep -q 'chat/completions' <<<"$out" && break
  done; echo "$out"
}

# agent_probe <url> [curl args]: curl INSIDE the agent pod; prints "<http_code> <curl_exit>".
# Blocked by the network = "000 7" (refused) or "000 28" (timeout). Empty / other exit = tooling error.
agent_probe() { kubectl exec -n "$AGENT_NS" "deploy/$AGENT_NAME" -c hermes -- \
                  sh -c 'curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 8 "$@"; echo " $?"' _ "$@" 2>/dev/null; }
