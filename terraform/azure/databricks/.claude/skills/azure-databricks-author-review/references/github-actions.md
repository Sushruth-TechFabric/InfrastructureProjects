# GitHub Actions (Terraform CI/CD) — best practices, cheat codes, docs

## Table of contents
1. The model: plan on PR, apply on merge
2. OIDC authentication (no stored secrets)
3. Environment approval gates
4. PR validation pipeline
5. Persisted plan, reusable workflows
6. Supply-chain hardening
7. Skeleton workflows
8. Common mistakes
9. Documentation links

---

## 1. The model
- The **pipeline is the only thing that applies** to shared environments — never a laptop.
  That's what makes review, gating, auditability, and controlled identity enforceable.
- **`plan` on every PR** (read-only, safe, posted for reviewers). **`apply` only after merge**
  to main. Different triggers = structural guarantee that nothing un-reviewed is applied.

## 2. OIDC authentication (no stored secrets)
- Grant the job `permissions: id-token: write` so GitHub mints a short-lived OIDC token;
  `azure/login` exchanges it for an Azure token. **No client secret in GitHub.**
- **Per-environment** service principal + federated credential, scoped to the GitHub
  Environment (`subject: repo:org/repo:environment:prod`). A dev pipeline can't auth as prod.
- Non-secret IDs (client/tenant/subscription) are plain config (Actions variables); only the
  ephemeral token is sensitive, and it's never stored.

## 3. Environment approval gates
- Define `dev`, `staging`, `prod` as **GitHub Environments**. On `prod`, add a **required
  reviewers** protection rule so the apply job pauses for a named human before running.
- This is the *apply-time* gate (timing/accountability), separate from PR review (content).
  Both guard different risks. dev/staging flow automatically; prod waits.

## 4. PR validation pipeline
Run on every PR, before human review, to shift failures left:
`terraform fmt -check` → `terraform validate` → **TFLint** → **Trivy/Checkov** security
scan → `terraform plan` (posted as a PR comment). Make these **required status checks**.

## 5. Persisted plan, reusable workflows
- Apply the **exact** reviewed plan: `terraform plan -out=tfplan` → upload as artifact →
  `terraform apply tfplan`. Prevents drift between review and apply.
- **Plan and apply must target the same environment** so the persisted artifact is valid:
  the plan that gets applied to `prod` must have been generated against `prod`'s backend +
  vars, not `dev`'s. With separate state per env, parameterize the env (reusable workflow
  input / matrix) rather than hardcoding `dev` in plan and `prod` in apply. The two
  skeletons below are illustrative single-env snippets, not a dev-plan→prod-apply flow.
- Plan/apply logic is near-identical per env → write a **reusable workflow** and call it
  with `environment` inputs (DRY, like modules).

## 6. Supply-chain hardening
- **Pin third-party actions to a full commit SHA**, not a mutable tag (`@v4`). Multiple
  popular actions, including IaC scanners, were compromised in a 2026 supply-chain incident —
  a moved tag can ship malicious code. SHA pinning is non-negotiable in prod pipelines.
- Enforce **branch protection** on main (require PR review + passing checks) or "merge =
  approved" is a lie. Use least-privilege `permissions:` per job.

## 7. Skeleton workflows
```yaml
# .github/workflows/terraform-plan.yml  (PR)
name: terraform-plan
on: { pull_request: { branches: [main] } }
permissions: { id-token: write, contents: read, pull-requests: write }
jobs:
  plan:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@<commit-sha>          # pin to SHA
      - uses: azure/login@<commit-sha>
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@<commit-sha>
      - run: terraform fmt -check -recursive
      - run: terraform init
      - run: terraform validate
      - run: trivy config .
      - run: terraform plan -out=tfplan
      - uses: actions/upload-artifact@<commit-sha>
        with: { name: tfplan, path: tfplan }
```
```yaml
# .github/workflows/terraform-apply.yml  (merge to main)
name: terraform-apply
on: { push: { branches: [main] } }
permissions: { id-token: write, contents: read }
jobs:
  apply:
    runs-on: ubuntu-latest
    environment: prod      # protection rule pauses here for required reviewer
    steps:
      - uses: actions/checkout@<commit-sha>
      - uses: azure/login@<commit-sha>
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - uses: hashicorp/setup-terraform@<commit-sha>
      - uses: actions/download-artifact@<commit-sha>
        with: { name: tfplan }
      - run: terraform init
      # Apply the EXACT plan that was reviewed (no re-plan), per §5.
      - run: terraform apply tfplan
```

## 8. Common mistakes
- Long-lived Azure credentials in GitHub secrets instead of OIDC (re-creates leak risk).
- Running `apply` on the PR (applies unreviewed code).
- One service principal for all environments (dev compromise reaches prod).
- Not persisting the plan → apply re-plans and may differ from what was reviewed.
- Unpinned (`@v4`) third-party actions → supply-chain exposure.

## 9. Documentation links
- OIDC overview: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- OIDC with Azure: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure
- azure/login action: https://github.com/Azure/login
- Environments & protection rules: https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment
- Reusable workflows: https://docs.github.com/en/actions/using-workflows/reusing-workflows
- Security hardening (SHA pinning, permissions): https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions
- setup-terraform: https://github.com/hashicorp/setup-terraform
