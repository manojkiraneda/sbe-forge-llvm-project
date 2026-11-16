# Scheduled PPE42 upstream rebases

`PPE42 upstream rebase` runs daily at **07:23 UTC**, and supports manual
`workflow_dispatch` with an optional forced candidate build. It does the work;
these are not commands a developer must execute each day.

1. Fetch upstream LLVM main and fast-forward the fork's `main` mirror.
2. Rebase the existing `ppe42/llvm-next` series in an isolated worktree.
3. Reuse exact previously reviewed resolutions from the trusted `git rerere`
   cache. Stop on novel conflicts or a merge-only manual resolution.
4. Publish a candidate named with the upstream and original next commit SHAs.
5. Stage that exact commit on `automation/ppe42-build` and explicitly dispatch
   its `PPE42 toolchain` workflow. This fixed branch shares its compiler caches
   across nightly builds; immutable candidate branches remain unchanged.
6. When that workflow completes successfully, the promotion workflow verifies
   its repository, event, workflow path, candidate name, and exact tested SHA.
   For builds on the fixed CI branch, resolve GitHub's recorded run SHA back to
   exactly one immutable candidate. Never promote the moving CI branch's tip.
7. Atomically create a backup tag and replace next with the tested candidate,
   using explicit leases to reject concurrent updates.

The compiler build does not hold an idle controller runner: promotion
is triggered by `workflow_run`. Candidates are retained for diagnosis. A failed,
cancelled, or skipped CI run never promotes next. Retrying the controller reuses
an existing candidate for the same inputs. `main` can advance even if rebasing
next fails; the next scheduled attempt still discovers the correct old base.

## One-time installation

Merge the workflows, config, script, and tests into the repository **default
branch**, currently `ppe42/llvm-21`. Scheduled and workflow-run controllers must
exist there. This does not change the default branch or rewrite llvm-21.

Create repository Actions secret **`PPE42_REBASE_TOKEN`**, restricted to this
repository with **Contents, Workflows, and Actions read/write**. A fine-grained
PAT or equivalent GitHub App installation token can provide these permissions;
a short-lived App token needs an external refresh mechanism if stored directly
as a secret. For an unattended long-term installation, use a dedicated bot PAT
with an appropriate expiration/rotation policy or adapt checkout authentication
to mint App tokens at job start. Normal `GITHUB_TOKEN` cannot grant the workflow
file update permission needed when rebasing upstream workflow changes.

Configure branch rules to permit this controller identity to fast-forward main
and force-update next and `automation/ppe42-build`. The script itself requires fast-forward ancestry for
main, tested-source leases for next, and an atomic backup. Do not enable
force-pushing to main on the controller's behalf.

## Nightly compiler caches

GitHub Actions caches are scoped to a branch (with a default-branch fallback).
Dispatching every build on a new candidate branch prevented one night's LLVM
main build from restoring the previous night's cache. It instead fell back to
the LLVM 21 default branch, causing substantial recompilation.

The `ci_branch` setting now keeps these dispatches on `automation/ppe42-build`.
The existing ccache and CMake/Ninja cache restore prefixes can therefore find
the most recent cache from that same branch. The first build may need to warm
this new branch's cache once. Later builds reuse compatible entries, but broad
upstream header, build-option, or tool changes can still require significant
recompilation. Cache reuse does not skip compiler checks or firmware tests.

The fixed branch is a staging ref only. Updates use an explicit lease, CI checks
out its recorded commit, and promotion still checks the immutable candidate and
the original next SHA. Older in-flight builds dispatched on immutable candidate
branches remain supported during migration. No cache artifacts are executed by
the privileged promotion controller.

## Incremental rebase preparation

The controller checks out only `.github` and `utils/ppe42`. Repository history
used for ancestry checks, rebasing, and promotion lives in a separate bare
repository under the runner's temporary directory. Its objects and refs are
cached with the `ppe42-rebase-history-v1-` prefix, independently of compiler
build caches and reviewed conflict resolutions.

On a warm cache, Git can negotiate from the previous fetched tips and reuse
already downloaded history and blobs. A cold or evicted cache still needs its
initial history fetch. Both preparation and promotion use this history store;
the trusted controller checkout remains separate from the rebased worktree.

Only `objects`, `refs`, and `packed-refs` are cached. Configuration, credential
headers, hooks, shallow boundaries, and worktree state are not cached. Each job
recreates configuration from its trusted checkout, reconnects the existing
reviewed-resolution cache, and enables lazy blob fetching for filtered packs.
Promotion restores this cache without writing a new one.

Long Git operations report their start, elapsed time every 30 seconds, and
completion time to stderr. JSON reports and GitHub output values remain on
their existing channels. This makes history fetching, worktree creation, and
rebasing distinguishable in the live Actions log.

The promotion token stays in controller jobs. Candidate CI receives its normal
existing workflow token, not `PPE42_REBASE_TOKEN`. Promotion executes only the
script from the trusted default branch and does not execute candidate artifacts.

There is no release tagging or modification of sbe-forge's toolchain lock.
Backup tags use `ppe42-next-backup/run-<CI-run-id>`, distinct from release tags.

## Failures and inspection

The controller uploads a manifest, rebase log, range comparison, and, on
conflicts, conflicting files, the stopped patch, and sequencer metadata.
The Actions summary explains whether preparation, dispatch, or promotion failed.
A real conflict or compiler API break still needs a developer fix; the cron job
cannot safely invent one. It leaves next untouched and tries the latest inputs
again the following day.

Configuration lives in `.github/ppe42-rebase.json`. Keep new work on next or
forward-port stable-line fixes explicitly; this job does not silently cherry-pick
new commits from llvm-21 or discard next's LLVM-main compatibility patches.

Run the controller's own integration tests without compiling LLVM:

```
python3 -m unittest discover -s utils/ppe42 -p 'test_rebase_next.py' -v
```

References:
- [Workflow triggering and token behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [Scheduled workflow rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
