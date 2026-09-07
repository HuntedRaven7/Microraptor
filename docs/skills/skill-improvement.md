---
name: skill-improvement
description: Adding, splitting, or refactoring skills.
metadata:
  type: meta-skill
  status: stable
  last_updated: 2026-07-20
---
# Skill Improvement

## When to Use

- Adding, splitting, or refactoring skills.

## When NOT to Use

- Regular development work.

## Rules

1. Keep `AGENTS.md` small; do not list deep context there.
2. Update only the skill that matches your change.
3. Remove `TODO/FIXME` and work-in-progress markers before merging.
4. Use Conventional Commits for commits and PR titles.

## Verification

- [ ] Any changed skill is listed in `docs/skills/index.md`.
- [ ] No new internal-only hostnames or proprietary names appear in `AGENTS.md` or skills.
