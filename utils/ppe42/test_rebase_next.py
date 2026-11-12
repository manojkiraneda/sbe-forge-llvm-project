"""End-to-end controller tests using tiny local repositories, never LLVM builds."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import rebase_next as bot


class RebaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.upstream = self.root / 'upstream'
        self.remote = self.root / 'fork.git'
        self.repo = self.root / 'controller'
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(self.upstream)], check=True)
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.com')]:
            bot.git(self.upstream, 'config', key, value)
        self.commit(self.upstream, 'common', 'base\n')
        self.base = bot.sha(self.upstream, 'HEAD')
        subprocess.run(['git', 'clone', '-q', '--bare', str(self.upstream), str(self.remote)], check=True)
        subprocess.run(['git', 'clone', '-q', str(self.remote), str(self.repo)], check=True)
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.com')]:
            bot.git(self.repo, 'config', key, value)
        bot.git(self.repo, 'switch', '-c', 'ppe42/llvm-next')
        self.commit(self.repo, 'ppe42', 'downstream\n')
        self.original = bot.sha(self.repo, 'HEAD')
        bot.git(self.repo, 'push', 'origin', 'ppe42/llvm-next')
        bot.git(self.repo, 'switch', 'main')
        self.config = {
            'upstream_url': str(self.upstream), 'upstream_ref': 'refs/heads/main',
            'mirror_branch': 'main', 'downstream_branch': 'ppe42/llvm-next',
            'candidate_prefix': 'automation/ppe42-rebase', 'backup_prefix': 'ppe42-next-backup',
            'ci_workflow': 'ppe42-toolchain.yml'}
        self.repository = 'example/compiler'

    def commit(self, repo, name, content):
        (repo / name).write_text(content)
        bot.git(repo, 'add', name)
        bot.git(repo, 'commit', '-qm', 'Update ' + name)
        return bot.sha(repo, 'HEAD')

    def advance(self):
        return self.commit(self.upstream, 'new-upstream', 'upstream\n')

    def prepare(self, force=False):
        return bot.prepare(self.repo, self.config, self.root / 'report', force)

    def remote_sha(self, ref):
        return bot.sha(self.remote, ref)

    def run_for(self, result):
        return {'id': 123, 'event': 'workflow_dispatch', 'status': 'completed',
                'conclusion': 'success', 'head_repository': {'full_name': self.repository},
                'path': '.github/workflows/ppe42-toolchain.yml',
                'head_branch': result['candidate'], 'head_sha': result['candidate_sha']}

    def promote(self, run):
        return bot.promote(self.repo, self.config, self.root / 'promotion', run, self.repository)

    def test_no_update_is_noop(self):
        self.assertEqual(self.prepare()['state'], 'noop')
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), self.original)

    def test_clean_candidate_does_not_change_next(self):
        latest = self.advance()
        result = self.prepare()
        self.assertEqual(result['state'], 'candidate')
        self.assertEqual(self.remote_sha('main'), latest)
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), self.original)
        self.assertTrue(bot.ancestor(self.repo, latest, result['candidate_sha']))
        self.assertEqual(bot.git(self.repo, 'show', result['candidate_sha'] + ':ppe42').stdout, 'downstream\n')
        self.assertFalse((self.root / 'report/worktree').exists())

    def test_retry_reuses_candidate(self):
        self.advance()
        first = self.prepare()
        # Report/worktree is removed on success, so the same controller can retry.
        second = self.prepare()
        self.assertEqual(first['candidate_sha'], second['candidate_sha'])
        self.assertTrue(second['reused'])

    def test_force_can_validate_unchanged_upstream(self):
        result = self.prepare(force=True)
        self.assertEqual(result['state'], 'candidate')
        self.assertEqual(result['candidate_sha'], self.original)

    def test_conflict_keeps_next_and_saves_report(self):
        bot.git(self.repo, 'switch', 'ppe42/llvm-next')
        local = self.commit(self.repo, 'common', 'different downstream\n')
        bot.git(self.repo, 'push', 'origin', 'ppe42/llvm-next')
        bot.git(self.repo, 'switch', 'main')
        latest = self.commit(self.upstream, 'common', 'different upstream\n')
        with self.assertRaisesRegex(bot.RebaseError, 'conflicted'):
            self.prepare()
        self.assertEqual(self.remote_sha('main'), latest)
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), local)
        self.assertIn('<<<<<<<', (self.root / 'report/conflicts/common').read_text())
        self.assertEqual(json.loads((self.root / 'report/manifest.json').read_text())['state'], 'conflict')
        self.assertFalse((self.root / 'report/worktree').exists())

    def test_exact_cached_resolution_is_reused(self):
        bot.git(self.repo, 'switch', 'ppe42/llvm-next')
        original = self.commit(self.repo, 'common', 'downstream edit\n')
        bot.git(self.repo, 'push', 'origin', 'ppe42/llvm-next')
        bot.git(self.repo, 'switch', 'main')
        latest = self.commit(self.upstream, 'common', 'upstream edit\n')
        bot.fetch(self.repo, str(self.upstream), ['+refs/heads/main:refs/remotes/training/main'])
        training = self.root / 'training'
        bot.git(self.repo, 'worktree', 'add', '--detach', str(training), original)
        failed = bot.git(training, '-c', 'rerere.enabled=true', 'rebase', '--onto',
                         latest, self.base, check=False)
        self.assertNotEqual(failed.returncode, 0)
        (training / 'common').write_text('reviewed combined result\n')
        bot.git(training, '-c', 'rerere.enabled=true', 'rerere')
        bot.git(training, 'add', 'common')
        bot.git(training, '-c', 'rerere.enabled=true', 'rebase', '--continue')
        bot.git(self.repo, 'worktree', 'remove', str(training))
        result = self.prepare()
        self.assertEqual(result['state'], 'candidate')
        self.assertEqual(bot.git(self.repo, 'show', result['candidate_sha'] + ':common').stdout,
                         'reviewed combined result\n')
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), original)

    def test_upstream_rewrite_is_rejected(self):
        bot.git(self.upstream, 'checkout', '--orphan', 'replacement')
        bot.git(self.upstream, 'rm', '-rf', '.')
        self.commit(self.upstream, 'replacement', 'different root\n')
        bot.git(self.upstream, 'branch', '-M', 'main')
        with self.assertRaisesRegex(bot.RebaseError, 'diverged'):
            self.prepare()
        self.assertEqual(self.remote_sha('main'), self.base)

    def test_upstream_absorbed_patch_is_safe(self):
        self.commit(self.upstream, 'ppe42', 'downstream\n')
        self.advance()
        result = self.prepare()
        self.assertEqual(result['state'], 'candidate')
        self.assertEqual(bot.git(self.repo, 'show', result['candidate_sha'] + ':ppe42').stdout, 'downstream\n')

    def test_merge_only_resolution_is_not_silently_dropped(self):
        bot.git(self.repo, 'switch', '-c', 'side', self.original)
        self.commit(self.repo, 'side', 'side change\n')
        bot.git(self.repo, 'switch', 'ppe42/llvm-next')
        self.commit(self.repo, 'next-change', 'next change\n')
        bot.git(self.repo, 'merge', '--no-ff', '--no-commit', 'side')
        self.commit(self.repo, 'merge-only', 'manual merge addition\n')
        original = bot.sha(self.repo, 'HEAD')
        bot.git(self.repo, 'push', 'origin', 'ppe42/llvm-next')
        bot.git(self.repo, 'switch', 'main')
        self.advance()
        with self.assertRaisesRegex(bot.RebaseError, 'manual resolution'):
            self.prepare()
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), original)
        self.assertTrue((self.root / 'report/merge-resolution.patch').is_file())

    def test_success_promotes_with_backup_and_is_idempotent(self):
        self.advance()
        result = self.prepare()
        run = self.run_for(result)
        self.assertEqual(self.promote(run)['state'], 'promoted')
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), result['candidate_sha'])
        self.assertEqual(self.remote_sha('refs/tags/ppe42-next-backup/run-123'), self.original)
        self.assertEqual(self.promote(run)['state'], 'already-promoted')

    def test_failed_forked_or_wrong_workflow_run_is_rejected(self):
        self.advance()
        run = self.run_for(self.prepare())
        variants = [('conclusion', 'failure'), ('event', 'pull_request'),
                    ('status', 'in_progress'), ('path', '.github/workflows/other.yml'),
                    ('head_repository', {'full_name': 'untrusted/fork'}),
                    ('head_branch', 'automation/ppe42-rebase/../../bad')]
        for key, value in variants:
            invalid = copy.deepcopy(run)
            invalid[key] = value
            with self.subTest(key=key), self.assertRaises(bot.RebaseError):
                self.promote(invalid)
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), self.original)

    def test_moved_candidate_is_not_promoted(self):
        self.advance()
        result = self.prepare()
        bot.git(self.repo, 'push', 'origin', '+' + self.original + ':refs/heads/' + result['candidate'])
        with self.assertRaisesRegex(bot.RebaseError, 'Candidate moved'):
            self.promote(self.run_for(result))

    def test_concurrent_next_update_is_preserved(self):
        self.advance()
        result = self.prepare()
        bot.git(self.repo, 'switch', 'ppe42/llvm-next')
        newer = self.commit(self.repo, 'concurrent', 'new fix\n')
        bot.git(self.repo, 'push', 'origin', 'ppe42/llvm-next')
        with self.assertRaisesRegex(bot.RebaseError, 'changed while CI'):
            self.promote(self.run_for(result))
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), newer)

    def test_race_at_promotion_is_rejected_atomically(self):
        self.advance()
        result = self.prepare()
        bot.git(self.repo, 'switch', 'ppe42/llvm-next')
        newer = self.commit(self.repo, 'concurrent', 'racing update\n')
        real_git = bot.git
        def raced(repo, *args, **kwargs):
            if args[:2] == ('push', '--atomic'):
                real_git(self.repo, 'push', 'origin', newer + ':refs/heads/ppe42/llvm-next')
            return real_git(repo, *args, **kwargs)
        with patch.object(bot, 'git', side_effect=raced), self.assertRaises(bot.RebaseError):
            self.promote(self.run_for(result))
        self.assertEqual(self.remote_sha('ppe42/llvm-next'), newer)
        self.assertNotEqual(bot.git(self.remote, 'show-ref', '--verify',
                                   'refs/tags/ppe42-next-backup/run-123', check=False).returncode, 0)


if __name__ == '__main__':
    unittest.main()
