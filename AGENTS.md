# Working rules

- Use short Conventional Commits, e.g. `feat: add region selection` or `fix: preserve focus`.
- Every commit is self-contained and passes lint, tests and build. Never commit broken intermediate states.
- Once the scaffold exists, run `make lint`, `make test` and `make build` successfully before every commit. Until then, use suitable checks and name missing ones explicitly.
- When working in parallel, respect the module and file ownership from `PLAN.md`; one separate worktree per package.
- Only create commits within the requested scope; respect an explicit “do not commit”.
