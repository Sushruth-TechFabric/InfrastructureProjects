# ADR-0014: Local module paths in the monorepo

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** Platform (Sushruth)

## Context

Every module call in this repo uses a local relative path
(`source = "../../modules/<name>"`). Generic Terraform guidance — including, until
now, this repo's own author-review skill (golden rule 5,
`references/terraform.md` §3) — instead prescribes pinning shared modules by git
tag (`?ref=vX.Y.Z`) so each environment can upgrade on its own schedule. The
2026-07 platform review (finding D1) flagged the contradiction: a skill that runs
as an isolated MUST-enforcing sub-review would flag or "rewrite" every working
module call, re-litigating the same non-defect each session.

The two conventions solve different problems. Git-tag pinning decouples module
evolution from consumers that live in **other** repos; this platform is a
**monorepo** — modules and every root that calls them ship from the same commit,
and the architecture doc's monorepo decision already assumes that.

## Decision

1. **Modules are referenced by local monorepo path** —
   `source = "../../modules/<name>"` — in every root
   (`environments/*`, `shared-services`). No git-tag or registry sources.

2. **The repo itself is the module version.** A commit is an atomic snapshot of
   the modules and all their callers; review of a module change is review of its
   effect on every consumer, in one diff. There is no per-module version number
   to maintain and no semantic-versioning contract to police.

3. **What still gets pinned:** providers via `required_providers`, Terraform core
   via `required_version = ">= 1.9, < 2.0"` (ADR-0005), and
   `.terraform.lock.hcl` is always committed per root.

4. **If a module is ever externalized** to its own repo or a private registry
   (e.g. to share it beyond this platform), git-tag pinning (`?ref=vX.Y.Z`) with
   semantic versioning becomes mandatory for that module at that moment — the
   skill retains that guidance as a conditional note, not a live rule.

## Consequences

- **Positive:** zero version-plumbing overhead; cross-module refactors land as
  one reviewable commit; a fresh clone always has exactly the module code its
  roots expect; the author-review skill no longer contradicts working code.
- **Negative / trade-off — lockstep upgrades:** every root picks up a module
  change on its **next plan/apply** — there is no per-root module version skew,
  so an environment cannot stay on an older module revision while others move
  ahead. A module edit intended for dev is a latent change for staging/prod the
  moment it merges; the mitigation is procedural, not mechanical: plan **every**
  calling root after a module change, and land risky module changes behind
  variables (off by default) rather than unconditional edits.
- **Follow-ups:** none required while the monorepo holds; revisit only when a
  module gains a consumer outside this repo.

## References

- 2026-07 platform review, finding D1
  (`docs/reviews/2026-07-terraform-and-docs-review.md` §5.1)
- ADR-0005 (version pinning — providers/core/lock file; unchanged by this ADR)
- `docs/architecture/azure-platform-architecture.md` (monorepo layout)
- `.claude/skills/azure-databricks-author-review/SKILL.md` golden rule 5;
  `references/terraform.md` §3
