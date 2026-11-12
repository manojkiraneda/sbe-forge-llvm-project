#!/usr/bin/env python3
"""Prepare a tested rebase candidate, or promote a successful candidate run."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


class RebaseError(RuntimeError):
    pass


def git(repo, *args, check=True):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env={**os.environ, "GIT_TERMINAL_PROMPT": "0",
                                     "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"})
    if check and result.returncode:
        raise RebaseError(result.stderr.strip() or result.stdout.strip())
    return result


def sha(repo, ref):
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").stdout.strip()


def ancestor(repo, older, newer):
    result = git(repo, "merge-base", "--is-ancestor", older, newer, check=False)
    if result.returncode not in (0, 1):
        raise RebaseError(result.stderr)
    return result.returncode == 0


def fetch(repo, remote, refs):
    args = ["fetch", "--no-tags", "--filter=blob:none"]
    shallow = git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() == "true"
    if shallow and remote == "origin":
        args.append("--unshallow")
        # The controller's default-branch commit may not be reachable from
        # main or next. Fetch origin HEAD too so its shallow boundary is
        # removed before contacting upstream, which cannot know that commit.
        refs = [*refs, "HEAD"]
    git(repo, *args, remote, *refs)


def origin_ref(branch):
    return "refs/remotes/origin/" + branch


def save(report, data):
    report.mkdir(parents=True, exist_ok=True)
    (report / "manifest.json").write_text(json.dumps(data, indent=2) + "\n")


def prepare(repo, config, report, force=False):
    mirror, downstream = config["mirror_branch"], config["downstream_branch"]
    fetch(repo, "origin", [f"+refs/heads/{b}:{origin_ref(b)}"
                           for b in (mirror, downstream)])
    fetch(repo, config["upstream_url"],
          [f'+{config["upstream_ref"]}:refs/remotes/ppe42-upstream/main'])
    old_main, old_next = sha(repo, origin_ref(mirror)), sha(repo, origin_ref(downstream))
    upstream = sha(repo, "refs/remotes/ppe42-upstream/main")
    data = {"state": "preparing", "old_main": old_main, "old_next": old_next,
            "upstream": upstream}
    save(report, data)
    if not ancestor(repo, old_main, upstream):
        raise RebaseError("Fork main has diverged from upstream; refusing to rewrite it")
    base = git(repo, "merge-base", old_main, old_next).stdout.strip()
    data["old_base"] = base
    # Recreating a merge can lose a manually added resolution even if the
    # recreated merge is clean. Require review for those exceptional stacks.
    for merge in git(repo, "rev-list", "--merges", f"{base}..{old_next}").stdout.splitlines():
        resolution = git(repo, "show", "--remerge-diff", "--format=", merge).stdout
        if resolution:
            (report / "merge-resolution.patch").write_text(resolution)
            data.update(state="blocked", merge_requiring_review=merge)
            save(report, data)
            raise RebaseError("Downstream merge has a manual resolution; refusing to discard it")
    # main is an upstream mirror, not a tested PPE42 compiler branch. It is
    # fast-forwarded even when the downstream candidate subsequently conflicts.
    if old_main != upstream:
        git(repo, "push", "origin", f"{upstream}:refs/heads/{mirror}")
    if ancestor(repo, upstream, old_next) and not force:
        data["state"] = "noop"
        save(report, data)
        return data
    candidate = f'{config["candidate_prefix"]}/{upstream}-{old_next}'
    existing = git(repo, "ls-remote", "--heads", "origin", f"refs/heads/{candidate}").stdout.split()
    if existing:
        # Committer dates make repeating a rebase non-deterministic. Reuse
        # the published candidate for these exact inputs instead of rewriting
        # it or manufacturing a second result on a controller retry.
        fetch(repo, "origin", [f"+refs/heads/{candidate}:{origin_ref(candidate)}"])
        tested = sha(repo, origin_ref(candidate))
        if not ancestor(repo, upstream, tested):
            raise RebaseError("Existing candidate does not contain its upstream snapshot")
        data.update(state="candidate", candidate=candidate, candidate_sha=tested, reused=True)
        save(report, data)
        return data
    tree = report / "worktree"
    git(repo, "worktree", "add", "--detach", str(tree), old_next)
    # The controller checkout, including this script, stays on the trusted
    # default branch. Only the isolated worktree is rebased.
    result = git(tree, "-c", "rerere.enabled=true", "-c", "rerere.autoupdate=true",
                 "rebase", "--rebase-merges", "--onto", upstream, base, check=False)
    log = result.stdout + result.stderr
    # rerere can stage an exact previously reviewed resolution, but rebase
    # still pauses. Continue only when the index has no unresolved paths.
    for _ in range(1000):
        if not result.returncode or git(tree, "ls-files", "-u").stdout:
            break
        state_dir = Path(git(tree, "rev-parse", "--absolute-git-dir").stdout.strip()) / "rebase-merge"
        if not state_dir.is_dir():
            break
        result = git(tree, "-c", "rerere.enabled=true", "-c", "rerere.autoupdate=true",
                     "rebase", "--continue", check=False)
        log += result.stdout + result.stderr
    (report / "rebase.log").write_text(log)
    if result.returncode:
        data.update(state="conflict", candidate=candidate)
        (report / "status.txt").write_text(git(tree, "status", "--short").stdout)
        (report / "conflicted-files.txt").write_text(
            git(tree, "diff", "--name-only", "--diff-filter=U").stdout)
        (report / "current.patch").write_text(
            git(tree, "rebase", "--show-current-patch", check=False).stdout)
        save(report, data)
        # Preserve only conflict files and sequencer metadata as diagnostics,
        # rather than uploading the multi-gigabyte LLVM working tree.
        import shutil
        for name in (report / "conflicted-files.txt").read_text().splitlines():
            source = tree / name
            if source.is_file():
                target = report / "conflicts" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        state = Path(git(tree, "rev-parse", "--absolute-git-dir").stdout.strip()) / "rebase-merge"
        if state.is_dir():
            shutil.copytree(state, report / "sequencer", dirs_exist_ok=True)
        git(tree, "rebase", "--abort", check=False)
        git(repo, "worktree", "remove", str(tree))
        raise RebaseError("Rebase conflicted; llvm-next was not changed. See the diagnostics artifact")
    tested = sha(tree, "HEAD")
    if not ancestor(tree, upstream, tested):
        raise RebaseError("Rebased candidate does not contain the selected upstream commit")
    before = int(git(tree, "rev-list", "--count", f"{base}..{old_next}").stdout)
    after = int(git(tree, "rev-list", "--count", f"{upstream}..{tested}").stdout)
    data.update(commits_before=before, commits_after=after)
    comparison = (git(tree, "range-diff", "--no-color", f"{base}..{old_next}",
                      f"{upstream}..{tested}").stdout if before and after else
                  f"Downstream commit counts: {before} before, {after} after; one range is empty.\n")
    (report / "range-diff.txt").write_text(comparison)
    # A name identifies immutable inputs. Never overwrite an existing candidate.
    remote = git(repo, "ls-remote", "--heads", "origin", f"refs/heads/{candidate}").stdout.split()
    if remote and remote[0] != tested:
        raise RebaseError("Candidate ref already exists with a different result")
    if not remote:
        git(repo, "push", f"--force-with-lease=refs/heads/{candidate}:",
            "origin", f"{tested}:refs/heads/{candidate}")
    git(repo, "worktree", "remove", str(tree))
    data.update(state="candidate", candidate=candidate, candidate_sha=tested)
    save(report, data)
    return data


def candidate_inputs(config, run, repository):
    if (run.get("event") != "workflow_dispatch" or
        run.get("status") != "completed" or run.get("conclusion") != "success" or
        run.get("head_repository", {}).get("full_name") != repository or
        run.get("path") != ".github/workflows/" + config["ci_workflow"]):
        raise RebaseError("Run is not a successful same-repository candidate toolchain dispatch")
    match = re.fullmatch(re.escape(config["candidate_prefix"]) +
                         r"/([0-9a-f]{40})-([0-9a-f]{40})", run.get("head_branch", ""))
    if not match or not re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")):
        raise RebaseError("Run has an invalid candidate name or commit")
    if not isinstance(run.get("id"), int):
        raise RebaseError("Run has no numeric ID")
    return match.groups()


def promote(repo, config, report, run, repository):
    upstream, old_next = candidate_inputs(config, run, repository)
    downstream, candidate = config["downstream_branch"], run["head_branch"]
    fetch(repo, "origin", [f"+refs/heads/{b}:{origin_ref(b)}"
                           for b in (config["mirror_branch"], downstream, candidate)])
    tested = run["head_sha"]
    if sha(repo, origin_ref(candidate)) != tested:
        raise RebaseError("Candidate moved after CI; refusing to promote an untested commit")
    if not ancestor(repo, upstream, tested) or not ancestor(repo, upstream, origin_ref(config["mirror_branch"])):
        raise RebaseError("Candidate upstream snapshot is not in candidate and mirror")
    current = sha(repo, origin_ref(downstream))
    data = {"state": "already-promoted", "old_next": old_next, "candidate_sha": tested,
            "ci_run": run["id"], "upstream": upstream}
    if current == tested:
        save(report, data)
        return data
    if current != old_next:
        raise RebaseError("llvm-next changed while CI was running; leaving it untouched")
    backup = f'refs/tags/{config["backup_prefix"]}/run-{run["id"]}'
    # Backup and promotion succeed together or not at all. Explicit leases
    # protect against races after the preceding fetch, including tag reuse.
    git(repo, "push", "--atomic", f"--force-with-lease=refs/heads/{downstream}:{old_next}",
        f"--force-with-lease={backup}:", "origin",
        f"{old_next}:{backup}", f"{tested}:refs/heads/{downstream}")
    data.update(state="promoted", backup=backup)
    save(report, data)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "promote"])
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, default=Path(".github/ppe42-rebase.json"))
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    report = args.report.resolve()
    try:
        if args.mode == "prepare":
            result = prepare(args.repo, config, report, args.force)
        else:
            if not args.repository or not args.run_id:
                parser.error("promotion requires --repository and --run-id")
            result = subprocess.run(["gh", "api", f"repos/{args.repository}/actions/runs/{args.run_id}"],
                                    check=True, text=True, stdout=subprocess.PIPE)
            result = promote(args.repo, config, report, json.loads(result.stdout), args.repository)
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a") as stream:
                for key in ("state", "candidate", "candidate_sha"):
                    if key in result:
                        stream.write(f"{key}={result[key]}\n")
        print(json.dumps(result, indent=2))
    except (RebaseError, subprocess.CalledProcessError) as error:
        report.mkdir(parents=True, exist_ok=True)
        (report / "error.txt").write_text(str(error) + "\n")
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
