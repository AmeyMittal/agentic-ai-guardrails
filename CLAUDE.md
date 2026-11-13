# Working conventions

How work is done in this repo. Anyone (or any tool) contributing here follows these rules.

## Rules

1. **Explain before applying.** Every manifest gets a plain-language comment on what it does and why. If a line can't be explained in a sentence, simplify it.
2. **Test-first.** Each acceptance check in `scripts/verify.sh` is written *before* the feature. Checks make real requests (status codes, log lines, network-level evidence), not "pod is Running". A check that can't fail proves nothing, so break the feature on purpose to show the check catches it.
3. **Independent review.** After each security-relevant milestone, the work is reviewed cold against [.claude/agents/qa-reviewer.md](.claude/agents/qa-reviewer.md): re-run the checks, look for bypass paths, secret leaks and demo risks. Blocking findings get fixed, or the trade-off gets recorded.
4. **Never read or print secrets.** Keys come from `.env` (gitignored) into Kubernetes Secrets. Never echo, log or commit them; compare them only inside commands. The agent never holds the real provider key; the gateway injects it. Use throwaway credentials with a spending cap.
5. **Verify, don't assume.** Versions and APIs move fast. Check schemas (`kubectl explain`, `--help`, upstream source and docs, real output) before relying on them. Pin every version.
6. **Log every problem** in [WHAT_BROKE.md](WHAT_BROKE.md): symptom → cause → fix → time taken.
7. **Go in milestones.** Stop at each one and prove it before moving on. Don't over-build: production hardening is documented in [ARCHITECTURE.md](ARCHITECTURE.md), not built.

## Design principles

- **Policy lives in the gateway, not the agent.** The agent only knows the gateway's address.
- **The agent never holds the provider key.**
- **Defence in depth:** gateway policy, no keys in the agent, built-in agent tools disabled, and a NetworkPolicy so the agent can only reach the gateway (plus DNS).
