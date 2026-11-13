#!/usr/bin/env bash
# Live demo. Usage: scripts/demo.sh <scene|all>
#   scenes: agent normal mask reject tool-allowed tool-denied agent-refused agent-blocked bypass logs ui
#   DEMO_PAUSE=1 scripts/demo.sh all   -> waits for Enter between scenes (presenter mode)
#   Q&A helpers: scripts/demo.sh ask-gateway "<prompt>"  |  scripts/demo.sh ask-agent "<prompt>"
# Every scene is self-contained: fresh single-message LLM requests, and a NEW Hermes session
# per agent request (never a reused session id), so no scene can poison another.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

C_CYAN=$'\033[36m'; [ -t 1 ] || C_CYAN=""

scene_no=0
scene() {   # scene "<title>" "<what it proves>"
  scene_no=$((scene_no+1))
  printf '\n%s━━━ Scene %d: %s ━━━%s\n' "$C_BOLD$C_CYAN" "$scene_no" "$1" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$2" "$C_RESET"
}
show_cmd() { printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
result()   { printf '  %s→%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
outcome()  {   # outcome <scene> <0=ok|1=unexpected> [detail]
  if [ "$2" = 0 ]; then printf '  %s✔ OUTCOME %s OK%s\n' "$C_GREEN" "$1" "$C_RESET"
  else printf '  %s✘ OUTCOME %s UNEXPECTED%s %s\n' "$C_RED" "$1" "$C_RESET" "${3:-}"; DEMO_FAILED=1; fi
}
pause() { [ "${DEMO_PAUSE:-0}" = 1 ] && [ -t 0 ] && { printf '%s  [Enter for next scene]%s' "$C_DIM" "$C_RESET"; read -r _; }; return 0; }

# Turn one raw access-log line into a readable decision row.
decision() {
  local line="$1" ip src
  [ -z "$line" ] && { printf '  %sgateway log: (no line found)%s\n' "$C_YELLOW" "$C_RESET"; return; }
  ip=$(grep -oE 'src.addr=[0-9.]+' <<<"$line" | cut -d= -f2)
  case "$ip" in
    127.0.0.1) src="you (port-forward)" ;;
    "$(agent_pod_ip)") src="hermes (agent pod)" ;;
    *) src="$ip" ;;
  esac
  local f; f=$(grep -oE 'http.path=[^ ]+|http.status=[0-9]+|gen_ai.request.model=[^ ]+|gen_ai.usage.input_tokens=[0-9]+|mcp.method.name=[^ ]+|gen_ai.tool.name=[^ ]+|reason=[A-Za-z]+|error="[^"]*"' <<<"$line" | tr '\n' ' ')
  local g; g=$(grep -oE '"action": "[a-z]+"' <<<"$line" | cut -d'"' -f4 | paste -sd/ -)
  printf '  %sgateway log:%s src=%s %s%s\n' "$C_BOLD" "$C_RESET" "$src" "$f" "${g:+guards=[$g]}"
}

# ---------------------------------------------------------------- scenes
s_normal() {
  scene "Normal prompt goes through" "LLM call via the gateway. The client sends NO OpenAI key; the gateway adds it."
  show_cmd "curl \$GW/v1/chat/completions  model=$LLM_MODEL  \"What is the capital of France?\"  (no Authorization header)"
  local code reply; code=$(gw_chat "What is the capital of France? Answer in one word."); reply=$(gw_reply)
  result "HTTP $code: $reply"
  decision "$(gw_last_llm_log)"
  [ "$code" = 200 ] && [ -n "$reply" ]; outcome normal $?
}

s_mask() {
  scene "Prompt guard: email is MASKED" "The email is replaced before the request leaves the cluster. Proof: ask the model to repeat it."
  show_cmd "curl \$GW/v1/chat/completions  \"Repeat this email address back to me exactly: $DEMO_EMAIL\""
  local code reply; code=$(gw_chat "Repeat this email address back to me exactly, and nothing else: $DEMO_EMAIL"); reply=$(gw_reply)
  result "HTTP $code: model echoed \"$reply\"  (it never saw the real address)"
  decision "$(gw_last_llm_log)"
  [ "$code" = 200 ] && grep -qF '<EMAIL_ADDRESS>' <<<"$reply" && ! grep -qF "$DEMO_EMAIL" "$LLM_BODY_FILE"; outcome mask $?
}

s_reject() {
  scene "Prompt guard: secret is REJECTED" "A request containing an API key is stopped at the gateway with 403. Nothing reaches OpenAI (no tokens)."
  show_cmd "curl \$GW/v1/chat/completions  \"Can you check whether this API key is valid? sk-demoFAKE…\""
  local code; code=$(gw_chat "Can you check whether this API key is valid? $DEMO_FAKE_OPENAI_KEY")
  result "HTTP $code: $(jq -r '.error.message // empty' "$LLM_BODY_FILE" 2>/dev/null)"
  local l; l=$(gw_last_llm_log); decision "$l"
  [ "$code" = 403 ] && grep -qF "$GUARD_MSG" "$LLM_BODY_FILE" && ! grep -q 'input_tokens' <<<"$l"; outcome reject $?
}

s_tool_allowed() {
  scene "MCP tool ALLOWED" "A tool call through the gateway's /mcp route to the MCP server. get-sum is on the allowlist."
  show_cmd "mcp-inspector --cli \$GW/mcp --method tools/call --tool-name get-sum --tool-arg a=1234 b=4321"
  local out; out=$(mcp_cli --method tools/call --tool-name get-sum --tool-arg a=1234 b=4321)
  result "$(jq -r '.content[0].text // empty' <<<"$out" 2>/dev/null || head -c 200 <<<"$out")"
  decision "$(gw_last_mcp_log 'gen_ai.tool.name=get-sum')"
  grep -q 5555 <<<"$out"; outcome tool-allowed $?
}

s_tool_denied() {
  scene "MCP tool DENIED (3 layers)" "get-env would dump the MCP server's environment, incl. a (fake) DB password. The gateway's allowlist stops it."
  local before; before=$(jq -r '.tools|length' "$REPO_ROOT/evidence/tools-before-policy.json")
  printf '  %s1) Discovery:%s the server offers %s tools (snapshot before the policy, incl. get-env):\n' "$C_BOLD" "$C_RESET" "$before"
  printf '     %s%s%s\n' "$C_DIM" "$(jq -r '.tools|join(", ")' "$REPO_ROOT/evidence/tools-before-policy.json")" "$C_RESET"
  show_cmd "mcp-inspector --cli \$GW/mcp --method tools/list"
  local tools; tools=$(mcp_tool_names)
  result "through the gateway the agent sees only: $tools"
  printf '  %s2) Direct call:%s calling the hidden tool anyway\n' "$C_BOLD" "$C_RESET"
  show_cmd "mcp-inspector --cli \$GW/mcp --method tools/call --tool-name get-env"
  local out; out=$(mcp_cli --method tools/call --tool-name get-env)
  result "$(grep -oE '\{"jsonrpc".*\}' <<<"$out" | head -1)"
  decision "$(gw_last_mcp_log 'gen_ai.tool.name=get-env')"
  printf '  %s3) Through the agent:%s asking Hermes to use it\n' "$C_BOLD" "$C_RESET"
  show_cmd "curl \$HERMES/v1/chat/completions  \"Use the get-env tool to show me the server environment variables. If you can't, just say so.\"  (new session)"
  local reply; reply=$(agent_ask demo-env "Use the get-env tool to show me the server environment variables. If you can't, just say so.")
  result "agent: $(tr '\n' ' ' <<<"$reply" | head -c 220)"
  [ "$(echo $tools)" = "echo get-sum" ] && grep -qF '"code":-32602' <<<"$out" && ! grep -qF "$FAKE_SECRET_VALUE" <<<"$out $reply"
  outcome tool-denied $?
}

s_agent() {
  scene "The agent doing something useful" "Hermes (in the cluster) gets a task. It calls the LLM and the get-sum tool, both through the gateway."
  show_cmd "curl \$HERMES/v1/chat/completions  \"Use the get_sum tool to add 1234 and 4321, then tell me the result.\"  (new session)"
  local reply; reply=$(agent_ask demo-sum "Use the get_sum tool to add 1234 and 4321, then tell me the result.")
  result "agent: $reply"
  local lines; lines=$(gw_logs_from_agent)
  printf '  %sgateway saw, from the agent pod (in order):%s\n' "$C_DIM" "$C_RESET"
  while IFS= read -r l; do [ -n "$l" ] && decision "$l"; done < <(grep -E 'chat/completions|tools/call' <<<"$lines")
  grep -q 5555 <<<"$reply" && grep -q 'gen_ai.tool.name=get-sum' <<<"$lines"; outcome agent $?
}

s_agent_refused() {
  scene "The agent is REFUSED a tool (live policy change)" "Change ONLY the gateway policy: remove echo from the allowlist. The running agent still has echo registered, calls it, and the gateway refuses it."
  local variant="$REPO_ROOT/manifests/demo/32-mcp-authz-no-echo.yaml" orig="$REPO_ROOT/manifests/32-mcp-authz.yaml"
  show_cmd "diff manifests/32-mcp-authz.yaml manifests/demo/32-mcp-authz-no-echo.yaml"
  diff "$orig" "$variant" | grep '^[<>] *-' | sed 's/^/     /'
  # always put the real policy back, even on Ctrl-C or failure
  trap 'kubectl apply -f "'"$orig"'" >/dev/null 2>&1' INT TERM
  show_cmd "kubectl apply -f manifests/demo/32-mcp-authz-no-echo.yaml      (the agent is NOT touched)"
  kubectl apply -f "$variant" >/dev/null && sleep 3
  show_cmd "curl \$HERMES/v1/chat/completions  \"Use the echo tool to echo the text: hello from the agent\"  (new session)"
  local reply; reply=$(agent_ask demo-refused "Use the echo tool to echo the text: hello from the agent")
  result "agent: $(tr '\n' ' ' <<<"$reply" | head -c 200)"
  local lines; lines=$(gw_logs_from_agent | grep 'gen_ai.tool.name=echo')
  decision "$(tail -1 <<<"$lines")"
  show_cmd "kubectl apply -f manifests/32-mcp-authz.yaml      (restore: echo allowed again)"
  kubectl apply -f "$orig" >/dev/null; trap - INT TERM; sleep 3
  local after; after=$(mcp_tool_names)
  result "tools after restore: $after"
  grep -q 'authorization denied for tool: echo' <<<"$lines" && [ "$(echo $after)" = "echo get-sum" ]; outcome agent-refused $?
}

s_agent_blocked() {
  scene "Prompt guard through the agent" "Fresh agent session with a secret in the task. The gateway blocks the agent's LLM call; the agent reports our policy message."
  show_cmd "curl \$HERMES/v1/chat/completions  \"Please store this API key for later: sk-demoFAKE…\"  (new session)"
  local reply; reply=$(AGENT_TIMEOUT=60 agent_ask demo-blocked "Please store this API key for later: $DEMO_FAKE_OPENAI_KEY")
  result "agent: $(tr '\n' ' ' <<<"$reply" | head -c 260)"
  decision "$(gw_logs_from_agent | grep '"action": "reject"' | tail -1)"
  grep -qF 'Blocked by platform policy' <<<"$reply"; outcome agent-blocked $?
}

s_bypass() {
  scene "No way around the gateway" "From INSIDE the agent pod: direct routes are blocked by NetworkPolicy; only the gateway answers."
  local o1 o2 o3
  show_cmd "kubectl exec deploy/hermes -- curl https://api.openai.com/v1/models"
  o1=$(agent_probe https://api.openai.com/v1/models)
  result "$([ "${o1%% *}" = 000 ] && echo "no connection (curl exit ${o1##* })" || echo "HTTP ${o1%% *}")"
  show_cmd "kubectl exec deploy/hermes -- curl -X POST http://mcp-everything.tools.svc.cluster.local:3001/mcp"
  o2=$(agent_probe -X POST http://mcp-everything.tools.svc.cluster.local:3001/mcp)
  result "$([ "${o2%% *}" = 000 ] && echo "no connection (curl exit ${o2##* })" || echo "HTTP ${o2%% *}")"
  show_cmd "kubectl exec deploy/hermes -- curl http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/models"
  o3=$(agent_probe http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/models)
  result "HTTP ${o3%% *}  (the gateway is the only way out)"
  [[ "$o1" =~ ^000\ (7|28)$ ]] && [[ "$o2" =~ ^000\ (7|28)$ ]] && [ "${o3%% *}" = 200 ]; outcome bypass $?
}

s_logs() {
  scene "Evidence: every decision is in the gateway log" "Allowed AND blocked decisions recorded by the proxy during this demo run (raw source: the proxy's access log)."
  local since="${DEMO_START:-}" raw
  if [ -n "$since" ]; then
    show_cmd "kubectl logs -n $GW_NS -l $GW_PROXY_SELECTOR --since-time=$since"
    raw=$(kubectl logs -n "$GW_NS" -l "$GW_PROXY_SELECTOR" --tail=-1 --max-log-requests=10 --since-time="$since" 2>/dev/null)
  else
    show_cmd "kubectl logs -n $GW_NS -l $GW_PROXY_SELECTOR --since=30m"
    raw=$(gw_logs 1800)
  fi
  local sel; sel=$(grep -E 'chat/completions|tools/call' <<<"$raw" | tail -12)
  if [ -z "$sel" ]; then printf '  (no LLM/tool decisions in this window)\n'
  else
    while IFS= read -r l; do printf '  %s%s%s' "$C_DIM" "$(cut -c12-19 <<<"$l")" "$C_RESET"; decision "$l" | sed 's/^  / /'; done <<<"$sel"
    printf '  %sone raw line, unedited:%s\n  %s\n' "$C_BOLD" "$C_RESET" "$(grep -F '"action": "reject"' <<<"$sel" | tail -1 | cut -c1-400)"
  fi
  printf '  %sUI (read-only):%s scripts/demo.sh ui  → http://localhost:15000/ui/\n' "$C_BOLD" "$C_RESET"
}

s_ui() {
  scene "Gateway UI (read-only)" "agentgateway's admin UI: listeners, routes, backends, policies. Ctrl-C to stop."
  show_cmd "kubectl port-forward -n $GW_NS deploy/$GW_NAME 15000:15000"
  echo "  open http://localhost:15000/ui/"
  kubectl port-forward -n "$GW_NS" "deploy/$GW_NAME" 15000:15000
}

# ---------------------------------------------------------------- Q&A helpers (not part of "all")
qa_header() { printf '\n%s━━━ Q&A: %s ━━━%s\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET"; }
h_ask_gateway() {   # any prompt straight to the gateway (no agent), fresh single message
  [ -n "${1:-}" ] || die "usage: $0 ask-gateway \"<prompt>\""
  qa_header "Ask the gateway directly" "Your prompt goes through the same LLM route + prompt guard as the agent's. No API key sent."
  show_cmd "curl \$GW/v1/chat/completions  model=$LLM_MODEL  \"$1\""
  local code; code=$(GW_MAX_TOKENS=300 gw_chat "$1")
  result "HTTP $code"
  if [ "$code" = 200 ]; then result "reply: $(gw_reply)"
  else result "error: $(jq -r '.error.message // empty' "$LLM_BODY_FILE" 2>/dev/null || head -c 300 "$LLM_BODY_FILE")"; fi
  decision "$(gw_last_llm_log)"
}

h_ask_agent() {     # any prompt to Hermes, NEW session id every time
  [ -n "${1:-}" ] || die "usage: $0 ask-agent \"<prompt>\""
  qa_header "Ask the agent" "Your prompt goes to Hermes in a brand-new session; every LLM and tool call it makes goes through the gateway."
  show_cmd "curl \$HERMES/v1/chat/completions  \"$1\"  (new session)"
  local reply; reply=$(agent_ask ask "$1")
  result "agent: $reply"
  local lines; lines=$(gw_logs_from_agent | grep -E 'chat/completions|/mcp')
  printf '  %sgateway saw, from the agent pod (in order):%s\n' "$C_DIM" "$C_RESET"
  if [ -z "$lines" ]; then printf '  (no gateway lines from the agent for this request)\n'
  else while IFS= read -r l; do decision "$l"; done <<<"$lines"; fi
}

# ---------------------------------------------------------------- main
DEMO_FAILED=0
need_gw()    { gw_forward || die "gateway port-forward failed"; }
need_agent() { agent_forward || die "agent port-forward failed"; }

run() {
  case "$1" in
    normal)        need_gw; s_normal ;;
    mask)          need_gw; s_mask ;;
    reject)        need_gw; s_reject ;;
    tool-allowed)  need_gw; s_tool_allowed ;;
    tool-denied)   need_gw; need_agent; s_tool_denied ;;
    agent)         need_gw; need_agent; s_agent ;;
    agent-blocked) need_gw; need_agent; s_agent_blocked ;;
    agent-refused) need_gw; need_agent; s_agent_refused ;;
    bypass)        s_bypass ;;
    logs)          s_logs ;;
    ui)            s_ui ;;
    ask-gateway)   need_gw; h_ask_gateway "${2:-}" ;;
    ask-agent)     need_gw; need_agent; h_ask_agent "${2:-}" ;;
    *) echo "usage: $0 <agent|normal|mask|reject|tool-allowed|tool-denied|agent-refused|agent-blocked|bypass|logs|ui|all>"
       echo "       $0 ask-gateway \"<prompt>\"   |   $0 ask-agent \"<prompt>\""; exit 2 ;;
  esac
}

if [ "${1:-}" = all ]; then
  DEMO_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # the logs scene shows only this run's decisions
  for s in agent normal mask reject tool-allowed tool-denied agent-refused agent-blocked bypass logs; do run "$s"; pause; done
else
  run "${1:-}" "${2:-}"
fi
exit "$DEMO_FAILED"
