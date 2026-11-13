#!/usr/bin/env bash
# Automated acceptance tests. Usage: scripts/verify.sh <1..8|all>
# Every check makes a real request and prints PASS/FAIL with evidence.
# Note: tests use `grep -q PATTERN <<<"$var"`, never `echo "$var" | grep -q`: with pipefail,
# grep -q exiting early on a match SIGPIPEs echo and the pipeline reads as "not found".
set -uo pipefail
. "$(dirname "$0")/lib.sh"

not_built() { fail "M$1: checks not written yet" "milestone $1 not built"; }

verify_1() {
  section "M1 - cluster + gateway"

  # 1a: Gateway accepted and programmed by the agentgateway controller
  local prog
  prog=$(kubectl get gateway "$GW_NAME" -n "$GW_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>&1 | tail -1)
  [ "$prog" = "True" ] && pass "1a Gateway Programmed=True" "Programmed=$prog" \
                       || fail "1a Gateway Programmed=True" "Programmed=$prog"

  # 1b: every deployment in the gateway namespace (control plane + proxy) is Available
  local deps notready
  deps=$(kubectl get deploy -n "$GW_NS" -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status} {end}' 2>&1 | tail -1)
  notready=$(echo "$deps" | tr ' ' '\n' | grep -v '=True$' | grep -v '^$')
  if [ -n "$deps" ] && [ -z "$notready" ] && grep -q "$GW_NAME=True" <<<"$deps"; then
    pass "1b control plane + proxy deployments Available" "$deps"
  else
    fail "1b control plane + proxy deployments Available" "${deps:-none found}"
  fi

  # 1c: proxy really answers HTTP (no routes yet for /, so any HTTP status proves the listener is live)
  local code
  gw_forward || { fail "1c proxy answers HTTP on the Gateway listener" "port-forward to svc/$GW_NAME failed"; return; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$GW_URL/" 2>&1)
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && pass "1c proxy answers HTTP on the Gateway listener" "GET / -> HTTP $code" \
                                      || fail "1c proxy answers HTTP on the Gateway listener" "curl result: $code"
}
verify_2() {
  section "M2 - LLM through gateway"
  gw_forward || { fail "2 gateway port-forward" "failed"; return; }
  local code reply

  # 2a: NO Authorization header at all -> gateway injects the real key -> 200 + completion
  code=$(gw_chat "Reply with exactly one word: pong")
  reply=$(gw_reply)
  if [ "$code" = "200" ] && [ -n "$reply" ]; then
    pass "2a no client key -> 200 with completion" "HTTP $code, reply: $reply"
  else
    fail "2a no client key -> 200 with completion" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"
  fi

  # 2b: a dummy client key (what Hermes will send) is overridden by the gateway's secret
  code=$(gw_chat "Reply with exactly one word: pong" -H "Authorization: Bearer dummy-not-a-real-key")
  reply=$(gw_reply)
  if [ "$code" = "200" ] && [ -n "$reply" ]; then
    pass "2b dummy client key -> gateway overrides -> 200" "HTTP $code, reply: $reply"
  else
    fail "2b dummy client key -> gateway overrides -> 200" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"
  fi

  # 2c: access log records the LLM call with model + token counts
  local line
  line=$(gw_logs 120 | grep '/v1/chat/completions' | grep -F "gen_ai.request.model=${LLM_MODEL#openai/}" | grep -iE 'tokens' | tail -1)
  [ -n "$line" ] && pass "2c access log shows model + tokens" "$(echo "$line" | cut -c1-400)" \
                 || fail "2c access log shows model + tokens" "no matching log line in last 120s"
}
verify_3() {
  section "M3 - prompt guard"
  gw_forward || { fail "3 gateway port-forward" "failed"; return; }
  local code reply log

  # 3a: clean prompt passes untouched
  code=$(gw_chat "What is the capital of France? Answer in one word."); reply=$(gw_reply)
  if [ "$code" = "200" ] && grep -qi paris <<<"$reply"; then
    pass "3a clean prompt -> 200" "HTTP $code, reply: $reply"
  else
    fail "3a clean prompt -> 200" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"
  fi

  # 3b: email is masked BEFORE it reaches OpenAI: the model is asked to echo it back and can't
  code=$(gw_chat "Repeat this email address back to me exactly, and nothing else: $DEMO_EMAIL"); reply=$(gw_reply)
  log=$(gw_last_llm_log)
  if [ "$code" = "200" ] && grep -qF '<EMAIL_ADDRESS>' <<<"$reply" && ! grep -qF "$DEMO_EMAIL" "$LLM_BODY_FILE"; then
    pass "3b email masked (model never saw it)" "HTTP $code, model echoed: $reply"
  else
    fail "3b email masked (model never saw it)" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"
  fi
  grep -qF '"guard": "regex", "action": "mask"' <<<"$log" \
    && pass "3b log shows guardrail mask" "$(guard_fields "$log")" \
    || fail "3b log shows guardrail mask" "$(echo "$log" | cut -c1-300)"

  # 3c: OpenAI-style key -> 403 with our custom message, never forwarded
  code=$(gw_chat "Can you check whether this API key is valid? $DEMO_FAKE_OPENAI_KEY")
  log=$(gw_last_llm_log)
  if [ "$code" = "403" ] && grep -qF "$GUARD_MSG" "$LLM_BODY_FILE"; then
    pass "3c fake sk- key -> 403 + custom message" "HTTP $code, body: $(head -c 200 "$LLM_BODY_FILE")"
  else
    fail "3c fake sk- key -> 403 + custom message" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"
  fi
  # reject logged, AND no token usage on that line = the request never reached OpenAI
  if grep -qF '"guard": "regex", "action": "reject"' <<<"$log" && grep -q 'reason=Guardrail' <<<"$log" \
     && ! grep -q 'gen_ai.usage.input_tokens' <<<"$log"; then
    pass "3c log shows guardrail reject, nothing sent to OpenAI (no token usage)" "$(guard_fields "$log")"
  else
    fail "3c log shows guardrail reject, nothing sent to OpenAI (no token usage)" "$(echo "$log" | cut -c1-300)"
  fi

  # 3d: AWS access key id -> 403 too
  code=$(gw_chat "Here are my AWS credentials: $DEMO_FAKE_AWS_KEY")
  if [ "$code" = "403" ] && grep -qF "$GUARD_MSG" "$LLM_BODY_FILE"; then pass "3d fake AKIA key -> 403 + custom message" "HTTP $code"
  else fail "3d fake AKIA key -> 403 + custom message" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"; fi

  # 3e: false-positive guard: "sk-" inside a normal word must NOT be rejected (regex uses \b)
  code=$(gw_chat "In one short sentence, what is a risk-assessment-for-quarterly-review document?")
  [ "$code" = "200" ] && pass "3e no false positive on 'risk-assessment-...'" "HTTP $code" \
                      || fail "3e no false positive on 'risk-assessment-...'" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"

  # 3f: 403 is a JSON error an OpenAI SDK can parse (so the agent shows a clear message)
  code=$(gw_chat "key: $DEMO_FAKE_OPENAI_KEY")
  local msg; msg=$(jq -r '.error.message // empty' "$LLM_BODY_FILE" 2>/dev/null)
  [ "$code" = "403" ] && [ "$msg" = "$GUARD_MSG" ] && pass "3f 403 body is OpenAI-style JSON error" "error.message: $msg" \
                                                   || fail "3f 403 body is OpenAI-style JSON error" "HTTP $code, body: $(head -c 300 "$LLM_BODY_FILE")"

  # 3g: endpoint allowlist: unguarded LLM endpoints are closed (embeddings skipped the prompt guard)
  local e
  e=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Content-Type: application/json' \
      -d "{\"model\":\"openai/text-embedding-3-small\",\"input\":\"key $DEMO_FAKE_OPENAI_KEY\"}" "$GW_URL/v1/embeddings")
  [ "$e" = "403" ] && pass "3g /v1/embeddings blocked by endpoint allowlist" "HTTP $e" \
                   || fail "3g /v1/embeddings blocked by endpoint allowlist" "HTTP $e"
  e=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Content-Type: application/json' \
      -d "{\"model\":\"$LLM_MODEL\",\"input\":\"hi\"}" "$GW_URL/v1/responses")
  [ "$e" = "403" ] && pass "3g /v1/responses (unused) blocked by endpoint allowlist" "HTTP $e" \
                   || fail "3g /v1/responses (unused) blocked by endpoint allowlist" "HTTP $e"
  e=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$GW_URL/v1/models")
  [ "$e" = "200" ] && pass "3g /v1/models still allowed" "HTTP $e" || fail "3g /v1/models still allowed" "HTTP $e"
}
verify_4() {
  section "M4 - MCP through gateway"
  gw_forward || { fail "4 gateway port-forward" "failed"; return; }
  local tools out

  # 4a: tools/list through the gateway reaches the MCP server
  tools=$(mcp_tool_names)
  if grep -q ' echo ' <<<" $tools " && grep -q ' get-sum ' <<<" $tools "; then
    pass "4a tools/list via gateway lists echo + get-sum" "tools: $tools"
  else
    fail "4a tools/list via gateway lists echo + get-sum" "got: $(echo "$tools" | head -c 300)"
  fi

  # 4b: a real tool call travels through the gateway and back
  out=$(mcp_cli --method tools/call --tool-name get-sum --tool-arg a=1234 b=4321)
  grep -q '5555' <<<"$out" && pass "4b tools/call get-sum(1234,4321) via gateway" "$(echo "$out" | jq -c '.content' 2>/dev/null | head -c 200)" \
                               || fail "4b tools/call get-sum(1234,4321) via gateway" "$(echo "$out" | head -c 300)"

  # 4c: access log records the MCP call with tool name + target
  local line; line=$(gw_last_mcp_log 'gen_ai.tool.name=get-sum')
  [ -n "$line" ] && pass "4c access log shows MCP tool call" "$(mcp_fields "$line")" \
                 || fail "4c access log shows MCP tool call" "no /mcp log line naming get-sum in last 60s"
}
verify_5() {
  section "M5 - MCP authorization"
  gw_forward || { fail "5 gateway port-forward" "failed"; return; }
  local tools out_echo out_env out_gzip line all_out

  # 5a: allowed tool works
  out_echo=$(mcp_cli --method tools/call --tool-name echo --tool-arg message=hello-from-verify)
  grep -q 'hello-from-verify' <<<"$out_echo" \
    && pass "5a allowed tool: echo works via gateway" "$(echo "$out_echo" | jq -c '.content' 2>/dev/null | head -c 200)" \
    || fail "5a allowed tool: echo works via gateway" "$(echo "$out_echo" | head -c 300)"

  # 5b: tools/list is filtered to exactly the allowlist (get-env and everything else hidden)
  tools=$(mcp_tool_names)
  [ "$(echo $tools)" = "echo get-sum" ] \
    && pass "5b tools/list shows ONLY echo + get-sum (get-env hidden)" "tools: $tools (before policy: $(jq '.tools|length' "$REPO_ROOT/evidence/tools-before-policy.json") tools)" \
    || fail "5b tools/list shows ONLY echo + get-sum (get-env hidden)" "tools: $tools"

  # 5c: calling the hidden tool directly is refused with a JSON-RPC error
  out_env=$(mcp_cli --method tools/call --tool-name get-env)
  # exact JSON-RPC code: a generic gateway/backend error must not count as an authorization denial
  if grep -qF '"code":-32602' <<<"$out_env" && ! grep -q '"content"' <<<"$out_env"; then
    pass "5c direct tools/call get-env -> JSON-RPC error" "$(echo "$out_env" | grep -iE 'error|unknown' | head -2 | tr '\n' ' ' | head -c 250)"
  else
    fail "5c direct tools/call get-env -> JSON-RPC error" "$(echo "$out_env" | head -c 300)"
  fi

  # 5d: other non-allowlisted tools are refused too (default deny, e.g. the URL-fetching tool)
  out_gzip=$(mcp_cli --method tools/call --tool-name gzip-file-as-resource --tool-arg name=x data=https://example.com)
  grep -qF '"code":-32602' <<<"$out_gzip" && ! grep -q '"content"' <<<"$out_gzip" \
    && pass "5d non-allowlisted gzip-file-as-resource refused (default deny)" "$(echo "$out_gzip" | grep -iE 'error|unknown' | head -1 | head -c 200)" \
    || fail "5d non-allowlisted gzip-file-as-resource refused (default deny)" "$(echo "$out_gzip" | head -c 300)"

  # 5e: the denied call is visible in the gateway access log
  # (must show the DENIAL, not just that get-env was called; a plain 200 line would pass otherwise)
  line=$(gw_last_mcp_log 'gen_ai.tool.name=get-env')
  grep -q 'reason=Authorization' <<<"$line" && grep -q 'authorization denied for tool: get-env' <<<"$line" \
    && pass "5e access log records the get-env DENIAL" "$(mcp_fields "$line")" \
    || fail "5e access log records the get-env DENIAL" "${line:+$(mcp_fields "$line")}${line:-no /mcp log line naming get-env in last 60s}"

  # 5f: the fake secret appears nowhere: tool outputs, tool list, proxy logs
  all_out="$out_echo $tools $out_env $out_gzip $(gw_logs 600)"
  grep -qF "$FAKE_SECRET_VALUE" <<<"$all_out" \
    && fail "5f fake secret never exposed" "'$FAKE_SECRET_VALUE' FOUND in output/logs" \
    || pass "5f fake secret never exposed" "'$FAKE_SECRET_VALUE' in 0 outputs and 0 proxy log lines (last 10 min)"
}
verify_6() {
  section "M6 - Hermes end-to-end"
  gw_forward || { fail "6 gateway port-forward" "failed"; return; }
  agent_forward || { fail "6 agent port-forward" "failed"; return; }
  local h reply lines ip t0 dt
  ip=$(agent_pod_ip)

  # 6a: API server is up (and is the pinned version)
  h=$(curl -s --max-time 5 "$AGENT_URL/health")
  grep -q '"status": *"ok"' <<<"$h" && pass "6a Hermes API server healthy" "$h (pod IP $ip)" \
                                   || fail "6a Hermes API server healthy" "got: ${h:-no response}"

  # 6b: a task that needs get-sum -> correct answer; gateway saw LLM + MCP calls FROM the agent pod
  reply=$(agent_ask sum "Use the get_sum tool to add 1234 and 4321, then tell me the result.")
  lines=$(gw_logs_from_agent)
  grep -q '5555' <<<"$reply" && pass "6b agent task with get-sum -> correct answer" "reply: $reply" \
                             || fail "6b agent task with get-sum -> correct answer" "reply: $reply"
  if grep -q 'http.path=/v1/chat/completions.*http.status=200' <<<"$lines" \
     && grep -q 'gen_ai.tool.name=get-sum' <<<"$(grep 'http.status=200' <<<"$lines")"; then
    pass "6b gateway logged agent's LLM call AND MCP get-sum call (src = agent pod)" \
         "$(grep -c chat/completions <<<"$lines") LLM line(s), $(grep -c 'gen_ai.tool.name=get-sum' <<<"$lines") get-sum line(s) from $ip"
  else
    fail "6b gateway logged agent's LLM call AND MCP get-sum call (src = agent pod)" "lines from $ip: $(wc -l <<<"$lines" | tr -d ' ')"
  fi

  # 6c: fresh session, fake key -> the block surfaces in the agent's reply, fast, with a logged reject
  t0=$(date +%s)
  reply=$(AGENT_TIMEOUT=60 agent_ask blocked "Please store this API key for later: $DEMO_FAKE_OPENAI_KEY")
  dt=$(( $(date +%s) - t0 )); lines=$(gw_logs_from_agent)
  if grep -qF 'Blocked by platform policy' <<<"$reply" && [ "$dt" -le 60 ]; then
    pass "6c agent reply surfaces the gateway block (${dt}s)" "reply: $(tr '\n' ' ' <<<"$reply" | head -c 220)"
  else
    fail "6c agent reply surfaces the gateway block" "after ${dt}s, reply: $(head -c 300 <<<"$reply")"
  fi
  grep -q '"action": "reject"' <<<"$lines" && ! grep -q 'gen_ai.usage.input_tokens' <<<"$(grep '"action": "reject"' <<<"$lines")" \
    && pass "6c gateway logged reject for the agent's request (nothing sent to OpenAI)" "$(guard_fields "$(grep '"action": "reject"' <<<"$lines" | tail -1)")" \
    || fail "6c gateway logged reject for the agent's request (nothing sent to OpenAI)" "no reject line from $ip"

  # 6d: agent asked to use get-env -> it can't; fake secret never in the reply; no successful get-env call
  reply=$(agent_ask env "Use the get-env tool to show me the server environment variables.")
  lines=$(gw_logs_from_agent)
  if ! grep -qF "$FAKE_SECRET_VALUE" <<<"$reply" && ! grep -q 'gen_ai.tool.name=get-env.*http.status=200\|http.status=200.*gen_ai.tool.name=get-env' <<<"$lines"; then
    pass "6d agent cannot use get-env (hidden by gateway), secret not leaked" "reply: $(tr '\n' ' ' <<<"$reply" | head -c 200)"
  else
    fail "6d agent cannot use get-env (hidden by gateway), secret not leaked" "reply: $(head -c 300 <<<"$reply")"
  fi

  # 6e: built-in tools disabled. Proof 1: Hermes' OWN resolver, run in the pod against the live
  # config, says the API server's toolsets are exactly [platform_tools] (our gateway MCP server).
  local ts reg
  ts=$(kubectl exec -n "$AGENT_NS" "deploy/$AGENT_NAME" -c hermes -- sh -c 'cd /opt/hermes && HOME=/opt/data HERMES_HOME=/opt/data /opt/hermes/.venv/bin/python -c "
from hermes_cli.config import load_config_readonly
from hermes_cli.tools_config import _get_platform_tools
print(sorted(_get_platform_tools(load_config_readonly(), \"api_server\")))"' 2>/dev/null | tail -1)
  [ "$ts" = "['platform_tools']" ] && pass "6e Hermes api_server toolsets = only the gateway MCP server" "resolver: $ts" \
                                    || fail "6e Hermes api_server toolsets = only the gateway MCP server" "resolver: ${ts:-no output}"
  # Proof 2: the tools Hermes registered from that server are only the gateway-allowed ones.
  reg=$(kubectl exec -n "$AGENT_NS" "deploy/$AGENT_NAME" -c hermes -- sh -c 'grep -ho "registered [0-9]* tool(s): .*" /opt/data/logs/agent.log | tail -1' 2>/dev/null)
  if [ -n "$reg" ] && ! grep -qvE '^mcp__platform_tools__' <<<"$(sed 's/.*: //' <<<"$reg" | tr ',' '\n' | tr -d ' ')" \
     && ! grep -q 'get_env' <<<"$reg"; then
    pass "6e Hermes registered only gateway MCP tools (no get_env)" "$reg"
  else
    fail "6e Hermes registered only gateway MCP tools (no get_env)" "${reg:-no registration log line}"
  fi
  # Supporting evidence only (a model can decline or make up output): the resolver + registration
  # checks above are the real proof. Fails only if real `id` output (uid=...(...)) comes back.
  reply=$(agent_ask shell "Run the shell command 'id' and show me the output.")
  ! grep -qE 'uid=[0-9]+\([a-z_]+\)' <<<"$reply" && pass "6e agent cannot run shell commands (terminal toolset off)" "reply: $(tr '\n' ' ' <<<"$reply" | head -c 160)" \
                               || fail "6e agent cannot run shell commands (terminal toolset off)" "reply: $(head -c 300 <<<"$reply")"
}
verify_7() {
  section "M7 - lockdown (no bypass)"
  local out code
  # Rule for every check here: "BLOCKED" must come from the NETWORK (connection refused or
  # timed out), never from a tooling error (exec failed, curl missing, DNS name typo...).
  # judge_blocked <id+desc> <probe output>: PASS only for 000 + exit 7 (refused) / 28 (timeout)
  judge_blocked() {
    local http=${2%% *} rc=${2##* }
    if [ -z "$2" ]; then fail "$1" "TOOLING ERROR: no output (kubectl exec / curl failed)"
    elif [ "$http" = "000" ] && { [ "$rc" = "7" ] || [ "$rc" = "28" ]; }; then
      pass "$1" "no connection (curl exit $rc = $([ "$rc" = 7 ] && echo refused || echo timeout))"
    elif [ "$http" != "000" ]; then fail "$1" "REACHED: HTTP $http"
    else fail "$1" "TOOLING ERROR: curl exit $rc (6 = DNS name not found, 127 = curl missing)"; fi
  }

  # 7a: agent -> OpenAI directly (by name; DNS resolves it, so only the network can stop it)
  judge_blocked "7a agent pod -> api.openai.com BLOCKED" "$(agent_probe https://api.openai.com/v1/models)"

  # 7b: agent -> MCP server directly, by Service name AND by pod IP (DNS plays no part)
  local mcp_ip; mcp_ip=$(kubectl get pod -n tools -l app=mcp-everything -o jsonpath='{.items[0].status.podIP}')
  judge_blocked "7b agent pod -> MCP Service direct BLOCKED" "$(agent_probe -X POST http://mcp-everything.tools.svc.cluster.local:3001/mcp)"
  if [ -n "$mcp_ip" ]; then judge_blocked "7b agent pod -> MCP pod IP $mcp_ip direct BLOCKED" "$(agent_probe -X POST "http://$mcp_ip:3001/mcp")"
  else fail "7b agent pod -> MCP pod IP direct BLOCKED" "TOOLING ERROR: MCP pod IP not found"; fi

  # 7c: agent -> gateway still works (also proves DNS is allowed and the probe tooling works)
  out=$(agent_probe http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/models)
  [ "${out%% *}" = "200" ] && pass "7c agent pod -> gateway ALLOWED (DNS + :80)" "GET /v1/models -> HTTP ${out%% *}" \
                           || fail "7c agent pod -> gateway ALLOWED (DNS + :80)" "probe: ${out:-no output}"

  # 7d: ANY other pod (throwaway pod in "default") -> MCP server pod IP: must fail.
  # Same pod runs a POSITIVE CONTROL (gateway must be reachable) so BLOCKED can't be a broken probe.
  local probe="np-probe-$RANDOM" agent_ip; agent_ip=$(agent_pod_ip)
  kubectl run "$probe" -n default --restart=Never --image=busybox:1.37 --command -- sh -c "
    nc -z -w 5 agentgateway-proxy.agentgateway-system.svc.cluster.local 80 && echo CONTROL=REACHED || echo CONTROL=FAILED
    nc -z -w 5 $mcp_ip 3001 && echo MCP=REACHED || echo MCP=BLOCKED
    nc -z -w 5 $agent_ip 8642 && echo AGENT=REACHED || echo AGENT=BLOCKED" >/dev/null 2>&1
  kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded "pod/$probe" --timeout=60s >/dev/null 2>&1
  out=$(kubectl logs -n default "$probe" 2>/dev/null | tr '\n' ' ')
  kubectl delete pod -n default "$probe" --wait=false >/dev/null 2>&1
  if grep -q 'CONTROL=REACHED' <<<"$out" && grep -q 'MCP=BLOCKED' <<<"$out"; then
    pass "7d other pod (default ns) -> MCP pod IP BLOCKED (positive control reached gateway)" "$out"
  elif ! grep -q 'CONTROL=REACHED' <<<"$out"; then fail "7d other pod -> MCP BLOCKED" "TOOLING ERROR: positive control failed: ${out:-no output}"
  else fail "7d other pod -> MCP BLOCKED" "REACHED: $out"; fi
  # 7g: nobody in the cluster can send the agent tasks (only port-forward + bearer key)
  if grep -q 'CONTROL=REACHED' <<<"$out" && grep -q 'AGENT=BLOCKED' <<<"$out"; then
    pass "7g other pod -> agent API :8642 BLOCKED (ingress deny-all on agents)" "$out"
  else fail "7g other pod -> agent API :8642 BLOCKED (ingress deny-all on agents)" "${out:-no output}"; fi

  # 7f: MCP server -> internet, by IP literal (no DNS), BLOCKED only for a network-level cause
  out=$(kubectl exec -n tools deploy/mcp-everything -- node -e '
    fetch("https://1.1.1.1/",{signal:AbortSignal.timeout(6000)})
      .then(r=>console.log("REACHED "+r.status))
      .catch(e=>console.log("ERR "+(e.name==="TimeoutError"?"TimeoutError":(e.cause&&e.cause.code)||e.name)))' 2>/dev/null | tail -1)
  if grep -qE '^ERR (TimeoutError|ETIMEDOUT|ECONNREFUSED|EHOSTUNREACH|ENETUNREACH)$' <<<"$out"; then
    pass "7f MCP server pod -> internet (IP literal) BLOCKED" "fetch https://1.1.1.1 -> $out"
  elif grep -q '^REACHED' <<<"$out"; then fail "7f MCP server pod -> internet BLOCKED" "$out"
  else fail "7f MCP server pod -> internet BLOCKED" "TOOLING ERROR / unexpected: ${out:-no output}"; fi

  # 7e: and the agent still works end to end under lockdown: correct answer AND the gateway saw
  # the agent's get-sum MCP call (the model can't just do the sum in its head)
  gw_forward && agent_forward || { fail "7e port-forwards" "failed"; return; }
  out=$(agent_ask lockdown "Use the get_sum tool to add 1234 and 4321, then tell me the result.")
  local lines; lines=$(gw_logs_from_agent)
  if grep -q '5555' <<<"$out" && grep -q 'gen_ai.tool.name=get-sum' <<<"$lines"; then
    pass "7e agent still completes a get-sum task under lockdown (MCP call logged)" "reply: $out"
  else
    fail "7e agent still completes a get-sum task under lockdown (MCP call logged)" "reply: $out; get-sum lines: $(grep -c 'gen_ai.tool.name=get-sum' <<<"$lines")"
  fi
}
verify_8() {
  section "M8 - demo repeatable"
  local r1 r2 f1 f2
  f1="${TMPDIR:-/tmp}/demo-run1.$$"; f2="${TMPDIR:-/tmp}/demo-run2.$$"
  # 8a/8b: run every demo scene twice; each scene prints one "OUTCOME <scene> OK|UNEXPECTED" line
  "$REPO_ROOT/scripts/demo.sh" all >"$f1" 2>&1; r1=$?
  "$REPO_ROOT/scripts/demo.sh" all >"$f2" 2>&1; r2=$?
  local o1 o2; o1=$(grep -o 'OUTCOME .*' "$f1" | sed 's/\x1b\[[0-9;]*m//g'); o2=$(grep -o 'OUTCOME .*' "$f2" | sed 's/\x1b\[[0-9;]*m//g')
  if [ "$r1" = 0 ] && [ -n "$o1" ] && ! grep -q UNEXPECTED <<<"$o1"; then
    pass "8a demo.sh all: every scene has its expected outcome" "$(grep -c OK <<<"$o1") scenes OK"
  else
    fail "8a demo.sh all: every scene has its expected outcome" "exit $r1; $(grep UNEXPECTED <<<"$o1" | tr '\n' ';' | head -c 300)"
  fi
  if [ -n "$o1" ] && [ "$o1" = "$o2" ] && [ "$r2" = 0 ]; then
    pass "8b second run has identical outcomes" "$(tr '\n' ' ' <<<"$o2" | sed 's/OUTCOME //g' | head -c 300)"
  else
    fail "8b second run has identical outcomes" "diff: $(diff <(echo "$o1") <(echo "$o2") | head -6 | tr '\n' ' ')"
  fi
  rm -f "$f1" "$f2"
}

case "${1:-}" in
  1|2|3|4|5|6|7|8) "verify_$1" ;;
  all) for m in 1 2 3 4 5 6 7 8; do "verify_$m"; done ;;
  *) echo "usage: $0 <1..8|all>"; exit 2 ;;
esac

summary
