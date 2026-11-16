# Landing and promotion (junderground)

`master` is the stable branch the app runs. `working` is the integration trunk:
agents branch from it, queue a committed branch, and the authority drains the
queue into `working`. `master` moves only by a fast-forward promotion, after the
full suite.

The queue is local to one clone. Tickets live in `<git-common-dir>/land-queue/`,
so every worktree of this checkout sees the same queue. Scratch worktrees and
logs live under `.land/` in the authority checkout.

## Queue a branch

Run from the worktree whose branch should land:

```sh
elixir scripts/land_enqueue.exs --trunk working
elixir scripts/land_enqueue.exs --trunk working --wait --timeout 300
```

The branch must be committed and the worktree clean. A ticket snapshots the
branch sha; re-running for the same queued branch refreshes the snapshot and
keeps its place. `--backup` pushes the branch to `origin` before writing the
ticket; it is off by default, so a local box needs no network to queue.

`--wait` exits 0 landed, 1 refused, 2 no verdict yet. Without it, the command
returns once the ticket exists.

## Drain the queue (authority)

Run from the checkout that should advance:

```sh
elixir scripts/land_coordinator.exs --once
elixir scripts/land_status.exs
elixir scripts/land_status.exs --all
elixir scripts/land_status.exs --refused --check
```

The coordinator takes the land lock, creates a detached scratch worktree at the
ticket sha under `.land/`, rebases it onto `working`, runs the test command once
with the authority's `deps` and `_build` shared, fast-forwards the local
`working`, and pushes it unless `--no-push`. It marks the ticket `landed` or
`refused` with a class: `rebase`, `suite`, `push`, `stale`, `trunk`, `primary`,
or `worktree`.

A refusal keeps the queue and the log (`<git-common-dir>/land-queue/<id>.log`).
Repair the branch once and enqueue it again. `land_status.exs --refused --check`
is the monitor's signal.

## Promote

```sh
elixir scripts/land_promote.exs --once
elixir scripts/land_promote.exs --once --dry-run
elixir scripts/land_promote.exs --once --no-push
```

Promotion is fast-forward only: `master` must be an ancestor of `working`. The
promoter takes the same land lock, runs the full suite in a scratch worktree at
the `working` tip, moves `master`, and pushes it unless `--no-push`. It refuses
on a red suite, a non-ancestor `master`, a dirty authority checkout, or a held
lock. `--dry-run` prints the plan and changes nothing.

## Why the authority checkout

The coordinator and promoter move the local trunk and expect a clean authority
checkout. Agent work belongs in worktrees under `.worktrees/`, not in the
authority tree. The lock is `<git-common-dir>/junderground-land.lock`; a stale
lock older than an hour is reclaimed.

## Enabling the hook

```sh
git config core.hooksPath .githooks
```

`.githooks/pre-push` runs `mix test`, `scripts/help_audit.exs`, and
`scripts/agent_help.exs --check`.
