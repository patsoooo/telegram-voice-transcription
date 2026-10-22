import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { plan, apply, parseArgs, repositoryRoot } from '../Scripts/integrate-telegram.mjs';

function git(host, ...args) {
  const result = spawnSync('git', ['-C', host, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function write(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, value); }
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'voice-installer-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const host = path.join(root, 'host');
  const featureRoot = path.join(root, 'feature');
  fs.mkdirSync(host);
  git(host, 'init', '-q');
  git(host, 'config', 'user.email', 'fixture@example.invalid');
  git(host, 'config', 'user.name', 'Fixture');
  write(path.join(host, 'BUILD'), 'deps = [\n]\n');
  write(path.join(host, 'versions.json'), '{"xcode":"26.6"}\n');
  git(host, 'add', '.'); git(host, 'commit', '-qm', 'baseline');
  const manifest = {
    schema_version: 1, commit: git(host, 'rev-parse', 'HEAD'), patch: 'host.patch',
    versions_source: 'versions.json', required_versions: { xcode: '26.6' },
    feature_module: { source: 'VoiceTranscriptScreen', host_destination: 'modules/VoiceTranscriptScreen', included_in_patch: false },
  };
  const patch = 'diff --git a/BUILD b/BUILD\n--- a/BUILD\n+++ b/BUILD\n@@ -1,2 +1,3 @@\n deps = [\n+        "//modules/VoiceTranscriptScreen",\n ]\n';
  write(path.join(featureRoot, 'Integration/host.patch'), patch);
  const save = () => write(path.join(featureRoot, 'Integration/host-manifest.json'), JSON.stringify(manifest));
  save();
  write(path.join(featureRoot, 'VoiceTranscriptScreen/BUILD'), 'swift_library()\n');
  write(path.join(featureRoot, 'VoiceTranscriptScreen/Sources/Nested/Test.swift'), 'struct Test {}\n');
  return { root, host, featureRoot, manifest, save, patch, destination: path.join(host, manifest.feature_module.host_destination) };
}
function snapshot(root) {
  const items = [];
  function walk(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name), stat = fs.lstatSync(file);
      items.push([path.relative(root, file), stat.mode, stat.mtimeMs, stat.isFile() ? fs.readFileSync(file).toString('base64') : stat.isSymbolicLink() ? fs.readlinkSync(file) : null]);
      if (stat.isDirectory()) walk(file);
    }
  }
  walk(root); return items;
}

test('default arguments, help, unknown and conflicting arguments', () => {
  assert.deepEqual(parseArgs(['--host', '/tmp/host']), { host: '/tmp/host', mode: 'check' });
  assert.deepEqual(parseArgs(['--help']), { help: true });
  for (const args of [[], ['--wat'], ['--host', 'relative'], ['--host', '/tmp', '--apply', '--check'], ['--host', '/tmp', '--host', '/tmp']]) assert.throws(() => parseArgs(args));
  const cli = spawnSync(process.execPath, [path.join(repositoryRoot, 'Scripts/integrate-telegram.mjs'), '--unknown'], { encoding: 'utf8' });
  assert.equal(cli.status, 1); assert.match(cli.stderr, /Unknown/);
});
test('read-only check plans missing recursive module and preserves all files including Git index', t => {
  const f = fixture(t), before = snapshot(f.root);
  const result = plan(f);
  assert.equal(result.patchState, 'unapplied');
  assert.deepEqual(result.missing, ['BUILD', 'Sources/Nested/Test.swift']);
  assert.deepEqual(snapshot(f.root), before);
});
test('wrong HEAD and ancestor Git root are rejected', t => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.host, 'child'));
  assert.throws(() => plan({ ...f, host: path.join(f.host, 'child') }), /exact Git toplevel/);
  f.manifest.commit = '0'.repeat(40); f.save();
  assert.throws(() => plan(f), /Wrong HEAD/);
});
test('apply fixture patch and module exclusively; subsequent apply is no-op', t => {
  const f = fixture(t);
  assert.equal(apply(f).copied, 2);
  const before = snapshot(f.host);
  assert.equal(plan(f).patchState, 'applied');
  assert.equal(apply(f).copied, 0);
  assert.deepEqual(snapshot(f.host), before);
});
test('already-applied patch with missing module is a successful read-only plan', t => {
  const f = fixture(t);
  git(f.host, 'apply', path.join(f.featureRoot, 'Integration/host.patch'));
  const before = snapshot(f.root);
  assert.equal(plan(f).patchState, 'applied');
  assert.equal(plan(f).missing.length, 2);
  assert.deepEqual(snapshot(f.root), before);
});
test('different existing module refuses with path and never overwrites', t => {
  const f = fixture(t);
  apply(f);
  const file = path.join(f.destination, 'Sources/Nested/Test.swift');
  write(file, 'user content');
  const before = snapshot(f.host);
  assert.throws(() => apply(f), error => error.message.includes(file) && error.message.includes('no overwrite'));
  assert.deepEqual(snapshot(f.host), before);
});
test('terminal LF differences are accepted in either direction without overwriting', t => {
  const f = fixture(t);
  apply(f);
  const name = 'Sources/Nested/Test.swift';
  const source = path.join(f.featureRoot, 'VoiceTranscriptScreen', name);
  const target = path.join(f.destination, name);
  for (const [sourceText, targetText] of [
    ['struct Test {}\n', 'struct Test {}' + '\n'.repeat(8)],
    ['struct Test {}\n\n', 'struct Test {}\n'],
    ['struct Test {}', 'struct Test {}\n'],
    ['struct Test {}\n', 'struct Test {}'],
  ]) {
    write(source, sourceText); write(target, targetText);
    const before = snapshot(f.root);
    const result = plan(f);
    assert.equal(result.normalizedEofFiles, 1);
    assert.deepEqual(result.identical, ['BUILD']);
    assert.deepEqual(result.missing, []);
    const applied = apply(f);
    assert.equal(applied.copied, 0);
    assert.equal(applied.normalizedEofFiles, 1);
    assert.deepEqual(snapshot(f.root), before);
  }
});
test('internal whitespace, trailing spaces, CR and other byte differences are rejected', t => {
  const f = fixture(t);
  apply(f);
  const source = path.join(f.featureRoot, 'VoiceTranscriptScreen/Sources/Nested/Test.swift');
  const target = path.join(f.destination, 'Sources/Nested/Test.swift');
  for (const [sourceText, targetText] of [
    ['struct Test {}\n', 'struct\nTest {}\n\n'],
    ['struct Test {}\n', 'struct  Test {}\n'],
    ['struct Test {}\n', 'struct Test {} \n\n'],
    ['struct Test {}\n', 'struct Test {}\r\n'],
    ['struct Test {}\n', 'struct Test {}\t\n'],
    ['first\nsecond\n', 'first\n\nsecond\n'],
    [Buffer.from([0xff, 0x0a]), Buffer.from([0xfe, 0x0a, 0x0a])],
  ]) {
    write(source, sourceText); write(target, targetText);
    const before = snapshot(f.root);
    assert.throws(() => plan(f), /Different existing module file \(no overwrite\)/);
    assert.throws(() => apply(f), /Different existing module file \(no overwrite\)/);
    assert.deepEqual(snapshot(f.root), before);
  }
});
test('empty and LF-only files compare safely, but other whitespace is not empty', t => {
  const f = fixture(t);
  apply(f);
  const source = path.join(f.featureRoot, 'VoiceTranscriptScreen/Sources/Nested/Test.swift');
  const target = path.join(f.destination, 'Sources/Nested/Test.swift');
  for (const [sourceText, targetText, normalized] of [
    ['', '', 0], ['', '\n\n', 1], ['\n\n', '', 1], ['\n', '\n\n', 1],
  ]) {
    write(source, sourceText); write(target, targetText);
    const before = snapshot(f.root);
    const result = plan(f);
    assert.equal(result.normalizedEofFiles, normalized);
    assert.equal(result.identical.length, 2 - normalized);
    assert.equal(apply(f).copied, 0);
    assert.deepEqual(snapshot(f.root), before);
  }
  for (const targetText of [' ', '\r', '\r\n', '\t\n']) {
    write(source, ''); write(target, targetText);
    const before = snapshot(f.root);
    assert.throws(() => apply(f), /Different existing module file \(no overwrite\)/);
    assert.deepEqual(snapshot(f.root), before);
  }
});
test('unrelated tracked, staged and untracked edits are rejected', t => {
  for (const kind of ['tracked', 'staged', 'untracked']) {
    const f = fixture(t);
    const file = kind === 'untracked' ? 'unrelated.txt' : 'versions.json';
    write(path.join(f.host, file), 'unrelated');
    if (kind === 'staged') git(f.host, 'add', file);
    assert.throws(() => plan(f), /Unrelated host modification/);
  }
});
test('unapplied patch refuses dirty baseline even for allowed documentation', t => {
  const f = fixture(t);
  write(path.join(f.host, 'docs/voice-transcript-reply.md'), 'notes');
  assert.equal(plan(f).patchState, 'unapplied');
  const before = snapshot(f.host);
  assert.throws(() => apply(f), /completely clean/);
  assert.deepEqual(snapshot(f.host), before);
});
test('manifest traversal, absolute paths and source symlinks are rejected', t => {
  for (const field of ['source', 'host_destination']) {
    for (const value of ['../escape', '/tmp/escape', 'safe/../../escape']) {
      const f = fixture(t); f.manifest.feature_module[field] = value; f.save();
      assert.throws(() => plan(f), /Unsafe relative path/);
    }
  }
  const f = fixture(t);
  fs.symlinkSync(path.join(f.host, 'BUILD'), path.join(f.featureRoot, 'VoiceTranscriptScreen/Sources/Link.swift'));
  assert.throws(() => plan(f), /Symlink/);
});
test('destination ancestor and patch target symlinks are rejected', t => {
  const f = fixture(t);
  fs.symlinkSync(f.featureRoot, path.join(f.host, 'modules'));
  assert.throws(() => plan(f), /Symlink/);
  const g = fixture(t);
  fs.unlinkSync(path.join(g.host, 'BUILD'));
  fs.symlinkSync(path.join(g.featureRoot, 'VoiceTranscriptScreen/BUILD'), path.join(g.host, 'BUILD'));
  assert.throws(() => plan(g), /Symlink/);
});
test('patch and versions manifest paths cannot escape their roots', t => {
  for (const field of ['patch', 'versions_source']) {
    const f = fixture(t); f.manifest[field] = '../outside'; f.save();
    assert.throws(() => plan(f), /Unsafe relative path/);
  }
});
test('incompatible patch and mismatched required host version are rejected', t => {
  const f = fixture(t);
  write(path.join(f.host, 'BUILD'), 'incompatible\n');
  assert.throws(() => plan(f), /incompatible/);
  const g = fixture(t); g.manifest.required_versions.xcode = '99'; g.save();
  assert.throws(() => plan(g), /Required host version/);
});
test('copy failure rolls back only installer-created files and leaves applied patch', t => {
  const f = fixture(t);
  git(f.host, 'apply', path.join(f.featureRoot, 'Integration/host.patch'));
  write(path.join(f.destination, 'BUILD'), 'swift_library()\n');
  write(path.join(f.featureRoot, 'VoiceTranscriptScreen/Sources/First.swift'), 'struct First {}\n');
  const original = fs.copyFileSync;
  let calls = 0;
  fs.copyFileSync = (...args) => { if (++calls === 2) throw new Error('simulated copy failure'); return original(...args); };
  try { assert.throws(() => apply(f), /Host patch was NOT reversed/); }
  finally { fs.copyFileSync = original; }
  assert.equal(fs.readFileSync(path.join(f.destination, 'BUILD'), 'utf8'), 'swift_library()\n');
  assert.equal(fs.existsSync(path.join(f.destination, 'Sources/First.swift')), false);
  assert.equal(plan(f).patchState, 'applied');
});

test('failure after newly applying patch leaves it applied and removes only new module files', t => {
  const f = fixture(t);
  const original = fs.copyFileSync;
  let calls = 0;
  fs.copyFileSync = (...args) => { if (++calls === 2) throw new Error('simulated failure'); return original(...args); };
  try { assert.throws(() => apply(f), /NOT reversed \(applied during this run\)/); }
  finally { fs.copyFileSync = original; }
  assert.equal(fs.existsSync(f.destination), false);
  assert.equal(plan(f).patchState, 'applied');
  assert.equal(plan(f).missing.length, 2);
});

test('destination leaf symlinks and malformed patch paths cannot overwrite anything', t => {
  const f = fixture(t);
  apply(f);
  const leaf = path.join(f.destination, 'BUILD');
  fs.unlinkSync(leaf);
  fs.symlinkSync(path.join(f.featureRoot, 'VoiceTranscriptScreen/BUILD'), leaf);
  assert.throws(() => plan(f), /Symlink/);
  const g = fixture(t);
  write(path.join(g.featureRoot, 'Integration/host.patch'), g.patch.replaceAll('a/BUILD', 'a/../BUILD').replaceAll('b/BUILD', 'b/../BUILD'));
  assert.throws(() => plan(g), /Unsafe relative path/);
});

// Opt-in read-only integration test; all mutation tests above use disposable fixtures.
test('source-repository CLI default check makes no host or source-module writes', {
  skip: !process.env.INTEGRATION_TEST_HOST && 'Set INTEGRATION_TEST_HOST to the pinned real checkout for the read-only CLI test',
}, () => {
  const host = fs.realpathSync(process.env.INTEGRATION_TEST_HOST);
  function fingerprint() {
    const digest = createHash('sha256');
    const add = value => digest.update(JSON.stringify(value));
    add(git(host, 'status', '--porcelain=v1', '-z', '--untracked-files=all'));
    add(git(host, 'diff', '--no-ext-diff', '--binary', 'HEAD'));
    const index = git(host, 'rev-parse', '--git-path', 'index');
    const indexPath = path.resolve(host, index);
    add(fs.readFileSync(indexPath).toString('base64'));
    add(fs.statSync(indexPath).mtimeMs);
    const untracked = git(host, 'ls-files', '--others', '--exclude-standard', '-z').split('\0').filter(Boolean);
    for (const name of untracked) {
      const file = path.join(host, name), stat = fs.lstatSync(file);
      add([name, stat.mode, stat.mtimeMs, stat.isSymbolicLink() ? fs.readlinkSync(file) : fs.readFileSync(file).toString('base64')]);
    }
    add(snapshot(path.join(repositoryRoot, 'VoiceTranscriptScreen')));
    add(fs.readdirSync(repositoryRoot).sort());
    add(fs.readdirSync(host).sort());
    return digest.digest('hex');
  }
  const before = fingerprint();
  const result = spawnSync(process.execPath, [path.join(repositoryRoot, 'Scripts/integrate-telegram.mjs'), '--host', host], {
    cwd: os.tmpdir(), encoding: 'utf8', env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /READ-ONLY CHECK/);
  assert.match(result.stdout, /No files changed/);
  assert.equal(fingerprint(), before);
});