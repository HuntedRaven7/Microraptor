---
name: onboarding
description: >-
  Bootstrap a new image from this template: rename the project, enable
  Actions and Renovate, protect the branch, and reach a first green build.
  Use when forking the template or when setup has stalled.
---

# Onboarding

Take a fresh fork from "Use this template" to a green build on `main`.

Every step has two routes: a `gh` command and a by-hand walkthrough through the
GitHub website (or `git`). They do the same thing, so use whichever suits you —
the by-hand route is written for someone who has never opened these settings
before. Substitute your own `{owner}/{repo}` throughout.

## Before you start

- You need **admin** on the repository for every step below.
- For the `gh` route, run `gh auth login` and authenticate as that admin.
- **Two different Settings pages are involved.** Most steps are in the
  *repository's* settings — open your repository and click **Settings** in the
  top bar. The token in step 5 is in your *account's* settings — click your
  profile picture, top right. They look similar; check the sidebar heading.
- Only step 5 has no shortcut, because only you can mint a personal access
  token.

## 1. Rename the project

See the Quick start in [README.md](../../../README.md#quick-start). Three identity
sites, and `just test-contract` fails when they disagree.

**Use the repository name in lowercase.** A repository name may carry capitals,
but the published image reference may not: podman rejects
`Error: tag MyImage:stable: invalid reference format: repository name must be
lowercase`, and `just build` passes `IMAGE_NAME` straight through to a tag. CI
does not hit this, because `build-image.yml` lowercases the event payload
(`IMAGE_NAME,,`) before it reaches the build — so a capitalised name produces a
green CI run and a local build that cannot start. `microraptor` is the name, not
`Microraptor`.

Do the rename before step 6. `stable` is created from `main`, so a repository
renamed afterwards has a `stable` branch carrying the old name's history.

## 2. Enable Actions

Without this no workflow runs at all, including the first build.

- **`gh`** — `gh api -X PUT repos/{owner}/{repo}/actions/permissions -F enabled=true -f allowed_actions=all`
- **By hand:**
  1. Open your repository and click the **Actions** tab.
  2. GitHub shows "Workflows aren't being run on this repository" with a green
     button. Click **I understand my workflows, go ahead and enable them**.
  3. To set the broader permission, go to **Settings → Actions → General**. Under
     **Actions permissions**, select **Allow all actions and reusable
     workflows**, then click **Save**.

## 3. Allow auto-merge

Renovate merges low-risk updates on its own, and it cannot without this.

> Renovate can also arrive as the **Renovate GitHub App** rather than as a token.
> When the App is installed, `app/renovate` opens the pull requests and
> `gh secret list` shows no `RENOVATE_TOKEN` — step 5 is then already satisfied,
> and the token job in `renovate.yml` logs "skipping Renovate" while the App
> keeps working. Check which one you have before treating an empty secret list as
> a failure: `gh pr list --author app/renovate` answers it.

- **`gh`** — `gh api -X PATCH repos/{owner}/{repo} -F allow_auto_merge=true`
- **By hand:**
  1. In your repository, click **Settings**.
  2. In the left sidebar, click **General**.
  3. Scroll down to **Pull Requests**.
  4. Tick **Allow auto-merge**. This section has no Save button; it applies
     immediately.
  5. **Automatically delete head branches** is optional. The template does not
     depend on it.

## 4. Workflow permissions

Two settings on one screen. The first lets workflows write — push images, open
pull requests. The second is what lets the promotion workflow approve the check
runs GitHub holds for its own pull request.

- **`gh`** — `gh api -X PUT repos/{owner}/{repo}/actions/permissions/workflow --input - <<'JSON'`
  ```json
  {"default_workflow_permissions": "write", "can_approve_pull_request_reviews": true}
  ```
  Use `--input`, not `-f`. `gh api`'s `-f` sends every value as a string, and
  this endpoint rejects a string where it wants a boolean:
  `Invalid property /can_approve_pull_request_reviews: `"true"` is not of type
  `boolean`` (HTTP 422). `-F` parses booleans, and `--input` sends the JSON
  verbatim; either works, `--input` is the one the API documents.
- **By hand:**
  1. **Settings → Actions → General**.
  2. Scroll down to **Workflow permissions**.
  3. Select **Read and write permissions**.
  4. Tick **Allow GitHub Actions to create and approve pull requests**.
  5. Click **Save**.

## 5. Create the Renovate token

The one step with no shortcut. Renovate uses this token to push branches and
open pull requests, so it needs to act as you.

Skip this step if you do not want Renovate. Without the secret the workflow logs
a skip and the run stays green; nothing else in the image depends on it.

### Create the token

1. On any GitHub page, click your profile picture in the top right, then
   **Settings**.
2. In the left sidebar, click **Developer settings**.
3. Under **Personal access tokens**, click **Tokens (classic)**.
4. Click **Generate new token**, then **Generate new token (classic)**.
5. Give it a **Note**, for example `renovate-your-repo`.
6. Set an **Expiration**. The default is 30 days. When it lapses, Renovate stops
   opening pull requests until you replace the secret, so pick a date you will
   notice.
7. Under **Select scopes**, tick:

   - **`repo`** — read and write the repository
   - **`workflow`** — update the files under `.github/workflows/`

8. Click **Generate token**.
9. **Copy the token now.** GitHub shows it once. If you lose it, generate
   another and replace the secret.

> A classic token carries every permission you have, on every repository you can
> reach. If you would rather not, create a fine-grained token instead, scoped to
> this repository, with **Contents: Read and write** and **Workflows: Write**.

### Store it as a secret

- **`gh`** — `gh secret set RENOVATE_TOKEN --repo {owner}/{repo}`, then paste the
  token when prompted.
- **By hand:**
  1. Back in your repository, go to **Settings → Secrets and variables →
     Actions**.
  2. Click **New repository secret**.
  3. Name it exactly **`RENOVATE_TOKEN`**.
  4. Paste the token into **Secret**, then click **Add secret**.

## 6. Create `stable`

Promotion opens a pull request *into* `stable`, so the branch has to exist before
the first promotion can run. Create it from `main`.

- **`git`** — from a clone: `git push origin main:stable`
- **`gh`** — `gh api -X POST repos/{owner}/{repo}/git/refs -f ref=refs/heads/stable -f sha="$(gh api repos/{owner}/{repo}/git/ref/heads/main --jq .object.sha)"`
- **By hand:**
  1. In your repository, click the branch dropdown in the file list — it reads
     **main**.
  2. Click **View all branches**, then **New branch**.
  3. Name it **`stable`** and set the source to **`main`**.
  4. Click **Create new branch**.

Never commit to `stable` directly. It only ever receives the promotion.

## 7. Protect `main`

Require the `validate` check, so nothing lands without passing shellcheck and
hadolint.

- **`gh`**:

  ```bash
  gh api -X PUT repos/{owner}/{repo}/branches/main/protection --input - <<'JSON'
  {
    "required_status_checks": {"strict": false, "contexts": ["validate"]},
    "enforce_admins": false,
    "required_pull_request_reviews": null,
    "restrictions": null
  }
  JSON
  ```

- **By hand:**
  1. **Settings → Branches** (newer repositories keep this under **Rules**).
  2. Click **Add branch protection rule**, or **Add classic branch protection
     rule**.
  3. **Branch name pattern**: `main`.
  4. Tick **Require status checks to pass before merging**.
  5. In the search box, type `validate` and select the **validate** check. It
     must be exactly `validate`. A check that has never run does not appear in
     the list — push something first if it is missing.
  6. **Require a pull request before merging** is optional. The template's
     convention is that `main` takes no direct pushes, but the setting is what
     enforces it.
  7. Click **Create**, or **Save changes**.

## 8. Protect `stable`

The same check, and **zero** required approvals so promotion merges the moment
checks pass.

- **`gh`** — the same call against `stable`, with:

  ```json
  "required_pull_request_reviews": {"required_approving_review_count": 0}
  ```

- **By hand:**
  1. **Settings → Branches → Add branch protection rule**.
  2. Pattern: `stable`.
  3. Tick **Require status checks to pass before merging** and select
     `validate`.
  4. Tick **Require a pull request before merging**, then set **Required
     approvals** to **0**. Zero is deliberate — with one or more, every
     promotion waits for a human.
  5. Click **Create**.

## 9. Restrict `stable` to squash merges

Promotion is a squash PR, so the branch should accept nothing else.

- **`gh`**:

  ```bash
  gh api -X POST repos/{owner}/{repo}/rulesets --input - <<'JSON'
  {
    "name": "stable — squash-only promotion",
    "target": "branch",
    "enforcement": "active",
    "conditions": {"ref_name": {"include": ["refs/heads/stable"], "exclude": []}},
    "rules": [{"type": "pull_request", "parameters": {
      "allowed_merge_methods": ["squash"],
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }}]
  }
  JSON
  ```

- **By hand:**
  1. **Settings → Rules → Rulesets**, then **New branch ruleset**.
  2. **Ruleset name**: `stable — squash-only promotion`.
  3. **Enforcement status**: **Active**.
  4. Under **Target branches**, click **Add target**, choose **Include by
     pattern**, and enter `stable`.
  5. Tick **Require a pull request before merging**.
  6. Under **Allowed merge methods**, tick **Squash** and untick the rest.
  7. Leave **Required approvals** at **0**.
  8. Click **Create**.

## 10. Create the labels

The release gate applies `release/ready` and `release/blocked`, and the shared
label workflow uses the lifecycle set. When a label is missing, the step that
applies it fails, and the failure is easy to miss.

- **`gh`** — one call per label:
  `gh label create <name> --repo {owner}/{repo} --color <hex> --force`
  (`--force` updates a label that already exists, so the block is safe to
  re-run.)
- **By hand** — **Issues → Labels → New label**, then name, colour, and
  description, one at a time. Twelve labels is tedious; the `gh` route is worth
  it here even if you did everything else by hand.

Required:

| Label | Colour |
|---|---|
| `release/ready` | `0e8a16` |
| `release/blocked` | `b60205` |
| `1-triage` | `FBCA04` |
| `2-discussing` | `D876E3` |
| `3-human-queue` | `1D76DB` |
| `3-clanker-queue` | `0E8A16` |
| `4-review` | `0052CC` |
| `blocked` | `B60205` |
| `hold` | `6E7781` |

Optional: `area/ci`, `kind/bug`, `priority/p1` (all `ededed`), and GitHub's
defaults.

`--force` is what makes this step re-runnable, which matters more than it looks:
the block is twelve `gh` calls with no transaction, so a failure at label seven
leaves the repository half-labelled and the obvious fix is to retype the whole
block. It is also the step most likely to be run twice, since a fresh fork often
inherits some of GitHub's defaults already.

## 11. Enable issues

The issue templates in `.github/ISSUE_TEMPLATE/` only appear when issues are on.

- **`gh`** — `gh api -X PATCH repos/{owner}/{repo} -F has_issues=true`
- **By hand:**
  1. **Settings → General**.
  2. Scroll to **Features**.
  3. Tick **Issues**.
  4. Click **Save**.

## Verify

Run every check and compare against the values in this skill:

```bash
gh api repos/{owner}/{repo} --jq '{auto_merge: .allow_auto_merge, issues: .has_issues}'
gh api repos/{owner}/{repo}/actions/permissions
gh api repos/{owner}/{repo}/actions/permissions/workflow
gh api repos/{owner}/{repo}/branches --jq '.[].name'
gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.contexts'
gh api repos/{owner}/{repo}/branches/stable/protection --jq '.required_status_checks.contexts'
gh api repos/{owner}/{repo}/rulesets --jq '.[].name'
gh secret list --repo {owner}/{repo}
```

Done when `main` and `stable` both exist and both require `validate`, the squash
ruleset is active, `RENOVATE_TOKEN` is set (or the Renovate App is installed),
and a push to `main` that changes more than documentation produces a green
`Build and Push Image` run and a `:stable-testing` image. Documentation-only
pushes are skipped by `paths-ignore`.

The one check above that does not cover the repository's own name: verify by hand
that `just build` starts. CI derives its image name from the event payload, so a
`Containerfile`, `Justfile` or `artifacthub-repo.yml` that disagrees with the
repository name, or that carries a capital the published reference may not,
produces a green CI run and a local build that cannot tag anything.

## Failure modes

- **The first build never starts** — Actions were never enabled (step 2).
- **`validate` is not offered as a check** — it has never run. Push something
  that is not documentation-only and try again.
- **Renovate opens no pull requests** — the token is missing, expired, or lacks
  the `workflow` scope (step 5).
- **The promotion PR never opens** — `stable` does not exist (step 6).
- **The promotion PR cannot merge** — `stable` requires an approval, or the
  check name is not exactly `validate` (steps 7–8).
- **The promotion PR is merged by hand** — expected on a personal repository. A
  merge queue needs an organization, so enrollment is off.
- **The release gate reports `release/blocked`** — the labels in step 10 are
  missing, or the candidate image is unsigned.
- **`gh api` returns 422 on the workflow permissions** — `-f` sent a string where
  the endpoint wants a boolean; use `--input` (step 4).
- **Renovate's PRs come from `app/renovate` and no secret is listed** — the App
  is installed and working. Step 5 does not apply.
- **`just build` fails with `repository name must be lowercase`** — the identity
  carries a capital that CI silently lowercases (step 1).
