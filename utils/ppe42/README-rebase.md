# Scheduled PPE42 upstream rebases

`PPE42 upstream rebase` runs daily at **07:23 UTC**, and supports manual
`workflow_dispatch` with an optional forced candidate build. It does the work;
these are not commands a developer must execute each day.

1. Fetch upstream LLVM main and fast-forward the fork's `main` mirror.
2. Rebase the existing `ppe42/llvm-next` series in an isolated worktree.
3. Reuse exact previously reviewed resolutions from the trusted `git rerere`
   cache. Stop on novel conflicts or a merge-only manual resolution.
4. Publish a candidate named with the upstream and original next commit SHAs.
5. Explicitly dispatch the candidate's `PPE42 toolchain` workflow.
6. When that workflow completes successfully, the promotion workflow verifies
   its repository, event, workflow path, candidate name, and exact tested SHA.
7. Atomically create a backup tag and replace next with the tested candidate,
   using explicit leases to reject concurrent updates.

The build can take hours without holding an idle controller runner: promotion
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
and force-update next. The script itself requires fast-forward ancestry for
main, tested-source leases for next, and an atomic backup. Do not enable
force-pushing to main on the controller's behalf.

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
