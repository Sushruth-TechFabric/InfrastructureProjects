@AGENTS.md

# Claude Code

This repo's instructions live in `AGENTS.md` (imported above) and the full
architecture reference in `docs/architecture/azure-platform-architecture.md`.
Keep this file thin — add only Claude-Code-specific behavior here so there is a
single source of truth.

- Use plan mode for any change touching more than one resource or any networking
  / identity / RBAC resource.
- Prefer editing a module over inlining resources into an environment root config.
- Never run `apply` against `prod`; stop at `plan` and hand off.
