# Project Guidelines — e-commerce

These rules apply to every contributor, human or AI agent, working on any of the e-commerce repositories:

| Repository | Scope |
|---|---|
| `e-commerce-WEB-FRONT` | Web front-end |
| `e-commerce-MOBILE-FRONT` | Mobile front-end |
| `e-commerce-BACK` | Back-end / API |
| `e-commerce-INFRA` | Infrastructure, CI/CD, deployment |

`CLAUDE.md` and `AGENT.md` are **identical** and must stay identical in all four repositories. Any change to one must be applied to both files, in all four repos.

---

## 1. Branching model

```
main      ●───────────────●──────────────●────────   (production — tagged releases only)
           \             ↑ v1.0.0       ↑ v1.0.1
dev         ●──●──●──●───●──────●──●────●──────────   (integration)
               ↑     ↑          ↑
feature/*   ───┘     │          │
fix/*       ─────────┘          │
hotfix/*   (from main) ─────────┴─→ main + dev
```

### Permanent branches

| Branch | Role | Rules |
|---|---|---|
| `main` | **Production.** Always reflects what is (or is about to be) deployed in prod. | Never commit directly. Only receives merges from `dev` (releases) or `hotfix/*`. Every release on `main` is tagged. |
| `dev` | **Integration.** All finished work is merged here first. | Never commit directly. Only receives merges from work branches through a Pull Request. Must always build and pass tests. |

### Work branches

Always created **from `dev`** (except hotfixes), and always merged back **into `dev`** via a Pull Request.

| Prefix | Use for | Example |
|---|---|---|
| `feature/` | New functionality | `feature/cart-checkout` |
| `fix/` | Non-urgent bug fix | `fix/price-rounding` |
| `refactor/` | Code restructuring, no behaviour change | `refactor/auth-service` |
| `docs/` | Documentation only | `docs/api-readme` |
| `chore/` | Tooling, dependencies, config | `chore/upgrade-node-22` |
| `test/` | Adding or fixing tests | `test/order-service` |
| `ci/` | CI/CD pipeline changes | `ci/add-lint-step` |
| `hotfix/` | **Urgent prod fix** — created from `main` | `hotfix/payment-crash` |

Branch naming rules:
- lowercase, words separated by hyphens: `feature/user-login`, not `Feature/UserLogin`
- short and descriptive (max ~50 chars)
- optionally include the issue number: `feature/42-user-login`
- one branch = one topic. Delete the branch once merged.

---

## 2. Workflows

### Feature / fix (normal flow)

```bash
git switch dev
git pull origin dev
git switch -c feature/my-feature

# ... work, commit often with conventional commits ...

git fetch origin
git rebase origin/dev          # keep the branch up to date, resolve conflicts locally
git push -u origin feature/my-feature
# open a Pull Request: feature/my-feature → dev
```

### Release (dev → main)

1. Make sure `dev` is green (build + tests pass) and contains everything planned for the release.
2. Open a Pull Request **`dev` → `main`** titled `release: vX.Y.Z`.
3. Once approved, merge it with a **merge commit** (no squash — keep the history of `dev`).
4. Tag the merge commit on `main` and push the tag (see §4). **The tag triggers the production deployment.**

### Hotfix (urgent prod bug)

```bash
git switch main
git pull origin main
git switch -c hotfix/short-description
# fix + commit (fix: ...)
git push -u origin hotfix/short-description
```

1. Open a PR **`hotfix/*` → `main`**, merge it, then tag with a **PATCH** bump (e.g. `v1.4.0` → `v1.4.1`).
2. **Immediately** merge `main` back into `dev` (or open a PR `hotfix/*` → `dev`) so the fix is not lost at the next release.

---

## 3. Conventional Commits

All commit messages **must** follow the [Conventional Commits 1.0.0](https://www.conventionalcommits.org/) specification.

### Format

```
<type>(<optional scope>): <short description>

<optional body>

<optional footer(s)>
```

### Types

| Type | When to use | Version impact |
|---|---|---|
| `feat` | A new feature | MINOR |
| `fix` | A bug fix | PATCH |
| `docs` | Documentation only | — |
| `style` | Formatting, whitespace, no code change | — |
| `refactor` | Code change that neither fixes a bug nor adds a feature | — |
| `perf` | Performance improvement | PATCH |
| `test` | Adding or correcting tests | — |
| `build` | Build system or external dependencies | — |
| `ci` | CI configuration and scripts | — |
| `chore` | Other changes that don't modify src or tests | — |
| `revert` | Reverts a previous commit | — |

A breaking change is marked with `!` after the type/scope **and/or** a `BREAKING CHANGE:` footer → **MAJOR** version bump.

### Rules

- Description in **English**, **imperative mood**, lowercase, no final period: `add cart page`, not `Added cart page.`
- Subject line ≤ **72 characters**.
- Scope is optional but encouraged, and should be a module/area name: `feat(cart): ...`, `fix(auth): ...`
- Body explains **what and why**, not how. Wrap at 72 characters. Separate from subject by a blank line.
- Reference issues in the footer: `Closes #12`, `Refs #34`.
- One logical change per commit. Don't mix a refactor and a feature in the same commit.
- Never commit commented-out code, debug logs, or unrelated formatting changes.

### Examples

```
feat(cart): add quantity selector on product line
```
```
fix(api): return 404 when product does not exist

Previously the endpoint returned 500 because the null result
was not handled.

Closes #27
```
```
feat(auth)!: replace session cookies with JWT

BREAKING CHANGE: clients must now send the Authorization header.
```
```
chore(deps): bump express from 4.19.2 to 4.21.0
```

---

## 4. Tags, versioning & deployment

- Versioning follows [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH` (e.g. `v1.3.0`).
  - **MAJOR**: breaking change (`!` / `BREAKING CHANGE`)
  - **MINOR**: new backwards-compatible feature (`feat`)
  - **PATCH**: backwards-compatible fix (`fix`, `perf`, hotfixes)
- **Tags are only created on `main`**, on the release/hotfix merge commit. Never tag `dev` or a work branch.
- **Pushing a `v*` tag is what triggers the production deployment.** Merging into `main` alone does not deploy.
- Always use **annotated** tags:

```bash
git switch main
git pull origin main
git tag -a v1.2.0 -m "release: v1.2.0"
git push origin v1.2.0
```

- Never delete, move or re-use a pushed tag. If a release is broken, fix it and publish a new PATCH version.
- Each repository is versioned independently. Coordinate releases when a change spans several repos (e.g. BACK API change + WEB-FRONT usage): release the back-end first, then the fronts.
- Pre-releases, if needed, use a suffix: `v1.2.0-rc.1`.

---

## 5. Pull Requests

- Every change goes through a Pull Request. **No direct pushes to `main` or `dev`.**
- Target branch: `dev` for all work branches; `main` only for releases (`dev` → `main`) and hotfixes.
- PR title follows the Conventional Commits format: `feat(cart): add quantity selector`.
- PR description must include:
  - **What** changed and **why**
  - **How to test** it
  - Linked issue(s): `Closes #12`
  - Screenshots for UI changes (WEB-FRONT / MOBILE-FRONT)
- At least **1 approval** from another team member before merging. Don't approve your own PR.
- CI must be green before merging.
- Keep PRs small and focused (ideally < 400 lines changed). Split large work into several PRs.
- Merge strategy:
  - work branch → `dev`: **Squash and merge** (the squashed commit message must be a valid conventional commit)
  - `dev` → `main`: **Merge commit**
  - `hotfix/*` → `main`: **Squash and merge**
- Delete the source branch after merge.

---

## 6. General Git best practices

- `git pull` before starting work; rebase your branch on `origin/dev` regularly to limit conflicts.
- Prefer `git rebase` on **your own** work branches; **never rewrite history** of `main`, `dev`, or a branch someone else is working on.
- **Never `git push --force`** to `main` or `dev`. On your own branch, use `git push --force-with-lease` only.
- Commit small and often; push at least once a day so work isn't lost.
- Review your diff before committing: `git diff --staged`.
- **Never commit secrets** (API keys, passwords, tokens, `.env` files, private keys, kubeconfigs, Terraform state). Use `.env.example` with placeholder values. If a secret is committed, consider it leaked: rotate it immediately and tell the team.
- Keep `.gitignore` up to date (`node_modules/`, build output, `.env`, IDE files, OS files, `*.tfstate`, ...).
- Don't commit generated files, build artifacts or large binaries.
- Resolve merge conflicts locally, then run the build and tests before pushing.

---

## 7. Rules specific to AI agents (Claude, Copilot, Codex, ...)

AI agents working in these repositories **must**:

1. Follow every rule in this file (branching, conventional commits, PRs, tags).
2. **Never commit or push directly to `main` or `dev`.** Always create a work branch from `dev` (or from `main` for a hotfix) with the correct prefix.
3. **Never create, move, delete or push tags**, and never trigger a deployment, unless a human explicitly asks for it in the current conversation.
4. **Never force-push**, rewrite shared history, or delete remote branches unless explicitly asked.
5. Never merge a Pull Request themselves unless explicitly asked.
6. Write commit messages and PR titles in Conventional Commits format.
7. Keep changes scoped to the task. No drive-by refactors or unrelated formatting.
8. Run the project's build, linter and tests before committing, and report failures honestly instead of hiding or skipping them.
9. Never commit secrets or `.env` files; never print secret values in logs or PR descriptions.
10. When unsure about a destructive or irreversible action, stop and ask a human.
11. Keep `CLAUDE.md` and `AGENT.md` identical; if one is updated, update the other in the same commit.

---

## 8. Quick reference

```bash
# start work
git switch dev && git pull && git switch -c feature/xxx

# commit
git commit -m "feat(scope): short description"

# update branch with latest dev
git fetch origin && git rebase origin/dev

# push & open PR to dev
git push -u origin feature/xxx

# release (after dev → main PR is merged)
git switch main && git pull && git tag -a vX.Y.Z -m "release: vX.Y.Z" && git push origin vX.Y.Z
```
