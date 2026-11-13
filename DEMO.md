# Demo guide

Audience: a customer's platform and security leads. About 45 minutes.

## Before the demo
1. Docker Desktop running. `kubectl config current-context` → `kind-agent-gw`.
2. **Preflight:** `scripts/verify.sh all` → expect all PASS. **Never** run teardown/setup on demo day.
   If a pod or port-forward misbehaves: `scripts/setup.sh` is safe to re-run (idempotent), and the scripts replace dead port-forwards automatically.
   **Laptop slept / Docker restarted?** Tested: after quitting and reopening Docker Desktop the cluster recovers by itself in ~70 s (Hermes waits for the gateway via its `wait-for-gateway` init step, WHAT_BROKE #15). Wait until `kubectl get pods -A` shows everything Running, then `scripts/verify.sh all`.
   **Rebuild from zero (only if the cluster is gone):** `scripts/setup.sh`, then `scripts/verify.sh all`. Took **103 s** on Nov 12 with images already cached on the Mac; **plan for 5–8 min** if Docker has to download the ~4 GB Hermes image again. Also check remaining OpenAI credit in the dashboard at T-30.
3. Open: this file, `ARCHITECTURE.md` (diagram renders in VS Code preview / GitHub), and a terminal at the repo root.
4. Optional second terminal: `scripts/demo.sh ui` → http://localhost:15000/ui/

## 1. Architecture (~10 min): `ARCHITECTURE.md`
- **Problem:** agents call LLMs and tools, and security wants one control point to see and stop what they do.
- **Walk the diagram:** agent → gateway → OpenAI (model traffic) and gateway → MCP server (tool traffic).
- **Three sentences to land:**
  1. *Policy lives in the gateway, not the agent.* The agent knows one address; swapping agent, model or tool server changes no policy.
  2. *The agent never holds the provider key.* The gateway injects it; the agent has a dummy.
  3. *Defence in depth:* gateway policy + no keys + agent configured gateway-only + NetworkPolicy, so even a manipulated agent has no other way out.
- Policies are Kubernetes resources: PR-reviewable, GitOps-able.

## 2. Live demo (~10–15 min): `DEMO_PAUSE=1 scripts/demo.sh all`
Each scene prints what it proves, the request, the result and **the gateway's own log line**. One `OUTCOME … OK` per scene. ~30 s total without pauses.

| # | Scene | Say |
|---|---|---|
| 1 | `agent` | "A task for the agent. It needs a tool. Watch the gateway log: LLM call, MCP `get-sum`, LLM call, all from the agent pod, all through the gateway." |
| 2 | `normal` | "Direct call to the gateway with **no API key**. 200. The gateway added the key." |
| 3 | `mask` | "An email in the prompt. I ask the model to repeat it, and it says `<EMAIL_ADDRESS>`. OpenAI never saw the address. Log: `guards=[mask/allow]`." |
| 4 | `reject` | "An API key in the prompt: 403 with our message, and **no token usage** in the log, so it never left the cluster." |
| 5 | `tool-allowed` | "Tool call through the gateway: `get-sum` is allowed." |
| 6 | `tool-denied` | "The server offers 16 tools, including `get-env`, which dumps its env vars (it holds a fake DB password; this server is **deliberately misconfigured**). Through the gateway: only `echo` and `get-sum`. Call it anyway: refused, logged as `authorization denied`. Ask the agent: it doesn't even know the tool exists." *If the agent offers to "run a command" instead:* "It can't: its built-in tools are off and the network only lets it reach the gateway; scene 9 shows that." |
| 7 | `agent-refused` | "Now the agent being **refused** a tool. I change only the gateway policy (one line: remove `echo`) and don't touch the agent. The agent still thinks it has `echo`, calls it, and the gateway refuses: `authorization denied for tool: echo`, from the agent pod. Then I put the policy back." *Policy lives in the gateway, live.* |
| 8 | `agent-blocked` | "Same secret, through the agent, fresh session. The agent quotes our policy message. (Hermes labels any 403 'rejected your API key'; the text after 'Provider said:' is ours.)" |
| 9 | `bypass` | "Could the agent go around? From inside its pod: OpenAI directly → no connection; MCP server directly → no connection; gateway → 200. NetworkPolicy." |
| 10 | `logs` | "Every decision during this demo, allowed or blocked, from the gateway's access log, plus one raw unedited line. That's the audit trail." Then the UI (`scripts/demo.sh ui`) if time. If asked for the raw source: `kubectl logs -n agentgateway-system -l app.kubernetes.io/name=agentgateway-proxy --tail=3`. |

**If the live demo fails:** run single scenes (`scripts/demo.sh mask` etc.). Direct-to-gateway scenes (2–5) don't depend on the agent.

## 3. What broke (~3 min): `WHAT_BROKE.md`
Pick 3 stories:
- **#5 (embeddings bypass):** the independent review found secrets could reach OpenAI via `/v1/embeddings`, which the prompt guard doesn't cover. Fixed with a fail-closed endpoint allowlist instead of a one-off block.
- **#7/#11/#14 (tests that couldn't fail):** a "secret never exposed" check that passed while the secret was exposed (SIGPIPE + pipefail); probes that counted a typo or a broken tool as "blocked". Fix: break the feature on purpose (mutation test) and only accept network-level evidence. *"A test that never fails proves nothing."*
- **#8/#9 (Hermes behind a gateway):** refused to run (couldn't discover the context window) and sent a parameter the model rejects. Both found by running it in Docker first and reading the source.

## 4. Q&A + live change: rehearsed, each verified on the live cluster
Each is one edit + `kubectl apply`; the change takes effect in ~3 s (agent changes ~15 s for the pod restart).

| Ask | Edit | Proof |
|---|---|---|
| Block another secret type (e.g. GitHub tokens) | `manifests/20-llm-openai.yaml`: add `- '\bghp_[A-Za-z0-9]{36}\b'` under the Reject `matches` | `scripts/demo.sh reject`-style curl with `ghp_…`: 200 before, **403 after** (rehearsed) |
| Make email stricter (Mask → Reject) | same file: Email guard `action: Mask` → `Reject` | email prompt → **403** (rehearsed). That guard has no `response:` block, so the client gets the gateway's default rejection text, not our JSON message; add one to customise |
| Allow another tool | `manifests/32-mcp-authz.yaml`: add `- 'mcp.tool.name == "get-tiny-image"'` | `tools/list` → `echo get-sum get-tiny-image` (rehearsed). Restart Hermes (`kubectl rollout restart deploy/hermes -n agents`) for the agent to see it |
| Deny a tool | remove its line from `32-mcp-authz.yaml` | `scripts/demo.sh tool-denied` |
| Swap the model | `manifests/40-hermes.yaml`: `default: "openai/gpt-4o-mini"`, apply, `kubectl rollout restart deploy/hermes -n agents` | `scripts/demo.sh agent` → log shows `gen_ai.request.model=gpt-4o-mini` (rehearsed; ready in 15 s; no gateway change) |

Before each live apply, catch typos with `kubectl apply --dry-run=server -f <file>`. Afterwards, re-run the matching scene. Revert after each: `git checkout manifests/ && kubectl apply -f manifests/<file>` (+ restart Hermes for 40).

### Ad-hoc questions: try any prompt live
For "what happens if I send …?" questions, use the questioner's own words:

| Command | What it does | Prints |
|---|---|---|
| `scripts/demo.sh ask-gateway "<prompt>"` | Sends the prompt **straight to the gateway** (no agent, no API key), same LLM route and prompt guard | HTTP status, the reply (or our 403 message), and the gateway's log line for that request (`guards=[…]`, tokens, reason) |
| `scripts/demo.sh ask-agent "<prompt>"` | Sends the prompt to **Hermes in a brand-new session** | the agent's reply and every gateway log line from the agent pod for that request: LLM calls and MCP tool calls in order |

Tried on the live cluster:
- `ask-gateway "Write a one-line greeting to bob.smith@acme.example and include his address."` → 200, `guards=[mask/allow]`, and the model **asked for the address**: it only ever saw a placeholder.
- `ask-gateway "Is this AWS key ID real? AKIAIOSFODNN7EXAMPLE"` → 403, our message, `reason=Guardrail`.
- `ask-agent "Add 17 and 25 with the get_sum tool, then echo the result with the echo tool."` → "42"; the gateway logged LLM → `get-sum` → LLM → `echo` → LLM, all from the agent pod.

Notes: quote the prompt; replies are capped at 300 tokens (`ask-gateway`); each call costs a fraction of a cent. A prompt containing a secret is blocked before it costs anything.

Likely questions are answered in the sections below (prompt-guard limits, MCP bypass attempts, the agent, model output → tool input, lockdown, residual paths, misconfigured server) and in `ARCHITECTURE.md` (scaling, production path).

---
# Technical notes and FAQ

## Model choice and fallback

- **Primary model:** `openai/gpt-4.1-mini-2025-04-14` (pinned dated snapshot, so behaviour can't shift under us before the demo).
  Chosen over `gpt-4o-mini` because it is more reliable at tool calling and following instructions, which the agent demo depends on. The cost difference is negligible at demo volume.
- **Fallback:** `openai/gpt-4o-mini`. Use it if 4.1-mini is unavailable or rate-limited.

### How to switch (no gateway change needed)
The gateway route matches `openai/*`, so any OpenAI model name passes through. Only the clients change:
1. Scripts: `export LLM_MODEL=openai/gpt-4o-mini` before `scripts/verify.sh` / `scripts/demo.sh` (default set in `scripts/lib.sh`).
2. Hermes (from M6): change `model.default` in the `manifests/40-hermes.yaml` ConfigMap, `kubectl apply`, restart the pod.

Talking point: *the model is chosen by the client within what the gateway allows. Swapping it touches no policy, and the guards apply to every model under `openai/*`.*

## Prompt guard: what it does and doesn't catch (be upfront)

Regex is **layer one**. These limits were found by the independent QA review and tested against the live gateway:

| Case | Result | Why |
|---|---|---|
| `sk-…`, `sk-proj-…` anywhere (system prompt, messages, assistant history, tool output, tool-call args, streaming, multiline, JSON-escaped) | 403 | Reject guard, all 4 scopes |
| `AKIA…` / `ASIA…` (AWS long-term / temporary key IDs) | 403 | Reject guard |
| `risk-assessment-for-quarterly-review` | 200 (no false positive) | `\b` word boundary |
| `sk-prod-cluster-eastus-nodepool-01` (resource name starting with `sk-`) | **403 (false positive)** | Looks like a key to a regex |
| Stripe `sk_live_…`, GitHub `ghp_…`, AWS *secret* keys, keys split by spaces or base64 | **200 (missed)** | Not in the pattern list / obfuscated |

**Talking point:** regex is cheap, fast and deterministic, but it has false positives and is easy to evade. In production, layer it: `openAIModeration` and/or a `webhook` (a vendor secret scanner or DLP) in the same `promptGuard` list, an `Audit` action first to measure false positives before switching to `Reject`, and per-team pattern lists.

**No response-side guard (decision):** guards run on requests, so sensitive data is stopped *before it leaves the cluster*. A response guard would only catch what the model makes up. `Mask` is also not applied to streamed responses. Adding a `response:` list later is one more YAML block.

**Endpoint allowlist** (`manifests/21-gateway-endpoint-allowlist.yaml`): the QA review found `/v1/embeddings` served by the same model route but **not prompt-guarded**. Instead of blocking it alone, the Gateway now only allows `/v1/chat/completions`, `/v1/models` and `/mcp`. Everything else gets 403 (`reason=Authorization` in the log). Fail-closed: a new endpoint stays shut until someone opens it on purpose.

## MCP authorization: what the review proved, and its limits

The independent QA review tried to get past the tool allowlist (all refused, `-32602` / 400 / 404, every denial logged with `reason`):
- name variants: `Get-Env`, `everything_get-env`, `"get-env "` (trailing space)
- other MCP features: `resources/read`, `prompts/get`, `completion/complete`, `resources/subscribe` (the Allow policy default-denies resources and prompts too)
- parser edge cases: batch arrays (400), a duplicate `name` key with echo then get-env (500, not forwarded)
- odd paths: `/MCP`, `//mcp`, `/mcp%2F` (404); forged backend session IDs (404)
- both protocol versions: 2025 sessions and the 2026-07-28 stateless mode (an `Mcp-Name` header/body mismatch gets -32020)

**Limit (talking point):** the allowlist filters *tool discovery and calls*. The server's free-text `initialize.instructions` passes through and *mentions* `get-env` by name (never the secret's value). An agent may therefore "know" the tool exists and try it, and that attempt is denied and logged. Per-field response filtering of server-supplied text is outside the policy's scope.

**Expect the question "why is the Gateway Service `<pending>`?"** It's type `LoadBalancer` and kind has no cloud load balancer. Agents reach it in-cluster by DNS name, and the demo uses `kubectl port-forward`. In a cloud cluster it would get an internal LB, or be switched to `ClusterIP`.

## The agent (Hermes v0.22.5): what to know for the demo

- **Fresh session per scene:** every request sends a **new, unique** `X-Hermes-Session-Id` (a new id means empty history). How Hermes behaves (verified in its source and by the M6 review): history is loaded from its database **only when the header is sent**. Without the header the model sees just the messages the client sent. The real risk is **reusing a fixed id** across scenes or demo runs: history builds up, and after a 403 Hermes keeps the user message "so context is preserved on retry", so a blocked string would poison every later turn in that session. `demo.sh` must never reuse an id.
- **What the blocked scene looks like:** the agent replies *"custom rejected your API key … Provider said: HTTP 403: Blocked by platform policy: request contains a secret/credential."* in ~1–2 s. Hermes labels any 403 as an auth problem ("custom" = our gateway's provider name); the policy text after "Provider said:" is ours. Say: *"the agent got our policy message verbatim, because the gateway returns an OpenAI-style JSON error."*
- **gpt-4.1-mini is marked non-reasoning** in the Hermes config (`model_overrides … supports_reasoning: false`). Without it, Hermes sent `reasoning_effort`, OpenAI answered `400`, and Hermes retried: one stray 400 per session (WHAT_BROKE #9). **If you switch to a reasoning model** (gpt-5-mini etc.), remove or flip that override.
- **The agent can't see `get-env`:** it answers "I do not have a get-env tool". The gateway filtered it from `tools/list` before Hermes registered its tools (`registered 2 tool(s): mcp__platform_tools__echo, mcp__platform_tools__get_sum`; the resource/prompt helpers are switched off in the Hermes config).
- **Built-in tools are off, two layers:** `platform_toolsets.api_server: [platform_tools]` (allowlist) + `agent.disabled_toolsets` (global strip). Proven with Hermes' *own* resolver in the pod: `api_server: ['platform_tools']`. Hermes itself warns at boot that an API server with the local terminal backend gives "full terminal/file access", which is exactly what we turned off.
- **The agent holds no OpenAI key:** 0 occurrences in its env, data dir, namespace objects and logs. Its config has a dummy key; the gateway injects the real one.
- **Agent replies that over-promise:** asked for env vars, it may offer to "use available Linux commands". It can't: built-ins are off, and (M7) the NetworkPolicy blocks everything but the gateway. Say so.
- **Turn cap:** `agent.max_turns: 10` limits cost and runaway loops per task (Hermes' default is unlimited).
- **Phone-home stopped:** with `model_catalog.enabled: false`, Hermes no longer fetches catalogs from openrouter.ai / nousresearch.com at boot (the M6 review found those cache files). M7's NetworkPolicy blocks any that remain.
- **Gateway probes:** at startup Hermes probes `/props`, `/api/tags`, `/version` on the gateway to discover the model's context window. All get 404 (not allowlisted), so `model.context_length` is set explicitly.

## Model output → tool input (found by the M6 review)

The reviewer asked the agent to echo `'sk-' + 'demoFAKE…'`:
1. The user message passed: the two pieces don't match the regex.
2. The model **assembled** the full fake key and called `echo` with it. That tool call goes from the agent straight to the gateway's `/mcp` route. The **prompt guard only inspects the LLM route**, so the MCP server received the key.
3. The next LLM request carried the tool call and its output back to the model. The guard scans those (ToolInput + ToolOutput scopes), so it got a **403**. The key never reached OpenAI.

**Answer:** the path to the LLM provider is covered end to end. *Model output → tool arguments* is not prompt-guarded today, because it's MCP traffic, not LLM traffic. Options:
- a response-side guard on the LLM route (catch the key as the model emits it)
- argument-level rules in the MCP authorization policy (CEL on the tool call)
- secret scanning on the MCP route via a webhook/ext-proc

## Lockdown (M7): the agent can only reach the gateway

`manifests/50-networkpolicy.yaml`, enforced by kindnet (tested empirically in M1):
1. **`agents` egress = DNS + gateway proxy pods :80 only.** From inside the Hermes pod: `api.openai.com` → no connection, `mcp-everything.tools:3001` → no connection, the gateway → 200.
2. **`tools` ingress = gateway proxy pods only.** A throwaway pod in `default` can't connect to the MCP server (closes the "any pod can call get-env directly" gap from the M4/M5 review).
3. **`tools` egress = none** *(added beyond the original plan)*. The MCP server's URL-fetching tool fetched `example.com` before; now it can't reach anything.

4. **`agents` ingress = none.** No pod can connect to the agent's API (a probe pod gets BLOCKED; its positive control reaches the gateway). Operators use `kubectl port-forward` (via the kubelet, gated by Kubernetes RBAC) plus the API bearer key. Answers *"who can send the agent tasks?"*
- **Applied first** in `setup.sh` (right after the namespaces): the agent and MCP server never run unrestricted, not even on first boot.

**Talking point:** *"Two independent layers: the agent is configured to use only the gateway, AND the network makes any other route impossible. Even a misconfigured or prompt-injected agent has no way out."*

**How the tests prove "blocked" (M7 review):** a block only counts if it comes from the network (curl exit 7 refused / 28 timeout, Node `TimeoutError`). A typo'd hostname (curl exit 6), a failed `kubectl exec` or a missing curl is reported as **TOOLING ERROR**, never as a pass. Cross-pod probes include a positive control (the gateway must be reachable from the same probe pod).

**Residual paths, be upfront (from the M7 review):**
- **DNS exfiltration:** kube-dns forwards external names upstream, so a compromised process could encode data in DNS queries via CoreDNS (direct DNS to 8.8.8.8/1.1.1.1 is blocked). Mitigated here because the agent has no shell/code tools. Production: FQDN-aware egress policy (Cilium/Calico DNS policy), a CoreDNS policy that only resolves `cluster.local` for agent namespaces, DNS query logging to the SIEM. *"Network egress is closed; DNS is the one deliberate hole, and here's how I'd close it."*
- **Gateway namespace has no policies:** from other pods, the control plane's xDS port (9978) and proxy metrics (15020) are reachable; the agent pod can't reach them. Production hardening: ingress policies on `agentgateway-system` too.
- **NodePort:** the gateway Service is type LoadBalancer, so it also has a NodePort (e.g. 31554) that the agent pod can reach. It's DNAT'd to the same proxy pods with the same policies, so it's the same gateway, not a bypass. Switching the Service to ClusterIP would remove the question.
- **Selector depends on the Gateway name:** policies select proxy pods by `app.kubernetes.io/name=agentgateway-proxy`, derived from the Gateway's name. It covers all replicas and rollouts. Renaming the Gateway would fail closed (safe, but breaks traffic).

**Fail-closed (shown live in M7):** gateway scaled to 0 → the agent answers *"custom didn't respond in time … Request timed out"* in ~1 min, and nothing goes anywhere else. Hermes then suggests *"add a backup provider"*, which is exactly what we must NOT do (a direct fallback = a bypass). The answer to "single point of failure" is **more gateway replicas** (stateless, horizontal), not a route around it.

**Boot under lockdown:** Hermes restarts Ready in ~15 s, first task in ~4 s, no connection errors (phone-home already disabled in M6).

## Review follow-ups (all resolved)
- **MCP server directly reachable** (M4/M5 review) → `tools` ingress policy + check 7d.
- **Agent never actually refused a tool** (final review) → scene `agent-refused`: live policy change, the agent's `echo` call is denied by the gateway (`authorization denied for tool: echo`, src = agent pod).
- **Long-lived Hermes MCP session across a policy change** → tested in `agent-refused`: the new policy applies to the agent's existing session immediately, and restoring it works without restarting Hermes. A tool *added* to the allowlist only appears to the agent after a Hermes restart (it lists tools at boot).
- **If the gateway proxy pod restarts mid-demo:** the scripts heal their port-forwards; to be safe also `kubectl rollout restart deploy/hermes -n agents` (~15 s).
- **"So anyone with port-forward rights bypasses the gateway?"** Yes: `kubectl port-forward` goes through the kubelet, not the pod network, so NetworkPolicy doesn't apply. Operator access is controlled by Kubernetes RBAC (who may port-forward/exec into `tools`). Live discovery proof if asked: `kubectl port-forward -n tools svc/mcp-everything 3001:3001` + Inspector `tools/list`.

## Known gaps / with more time
- **MCP server image:** base image pinned by digest and package by version, but transitive npm deps aren't lock-filed, and the build needs npm access. Production: build in CI, push to a registry, deploy by digest.
- **Test harness:** `port_forward` reuses a listener only if it answers HTTP; a dead one is replaced (WHAT_BROKE #12). `teardown.sh` kills every `kubectl port-forward` on the Mac.
- **LLM request timeout (decision):** `AgentgatewayModel.spec.policies` has no timeout field in v1.7; the only option is a Gateway-wide `traffic.timeouts`, which would also cut MCP's long-lived streaming connections. So the timeout is enforced client-side: Hermes gives up in ~1 min and reports it (`auto_recovery_cycles: 0`, WHAT_BROKE #13). Production: a per-route timeout on the LLM HTTPRoute once the model route is attached via an HTTPRoute parent.

## The MCP server is *deliberately misconfigured*

`manifests/30-mcp-server.yaml` runs the reference MCP "everything" server with:
- `FAKE_DB_PASSWORD=hunter2-demo`: a **fake** credential, the demo's stake.
- `GET_ENV_INCLUDE_SECRETS=1`: turns **off** the server's own protection. By default its `get-env` tool redacts names containing PASSWORD/KEY/TOKEN; with this set it returns them in plain text.

**Why:** this simulates a real risk, a tool server someone configured badly. Called directly (no gateway), `get-env` returns `"FAKE_DB_PASSWORD": "hunter2-demo"` (checked in M4, before any policy). With the gateway's MCP authorization rule (M5), the agent can neither see nor call `get-env`.

**Talking point:** *defence in depth: the platform doesn't rely on every tool server being configured correctly. The control point enforces which tools an agent may use, whatever the server exposes.* Nothing real is at risk: the pod's env holds only the fake value.
