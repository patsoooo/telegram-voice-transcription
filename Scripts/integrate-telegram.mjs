#!/usr/bin/env node
// Node >=18, no dependencies. Importing this module never runs the CLI.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const optionalDoc = 'docs/voice-transcript-reply.md';
const fail = message => { throw new Error(message); };
const exists = file => { try { return fs.lstatSync(file); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } };

// Ignore only terminal LF bytes (0x0a), never CR, spaces, or internal whitespace.
function withoutTerminalLf(bytes) {
  let end = bytes.length;
  while (end > 0 && bytes[end - 1] === 0x0a) end--;
  return bytes.subarray(0, end);
}

function relative(value) {
  if (typeof value !== 'string' || !value || value.includes('\\') || /[\x00-\x1f]/.test(value)
      || path.posix.isAbsolute(value) || value.split('/').some(p => !p || p === '.' || p === '..')) {
    fail(`Unsafe relative path: ${JSON.stringify(value)}`);
  }
  return value;
}

// Reject symlinks even when their targets would happen to remain in the root.
function safePath(root, value) {
  relative(value);
  let current = root;
  for (const part of value.split('/')) {
    current = path.join(current, part);
    const stat = exists(current);
    if (stat?.isSymbolicLink()) fail(`Symlink component refused: ${current}`);
  }
  return current;
}

function command(executable, args, cwd) {
  return spawnSync(executable, args, {
    cwd, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
  });
}

function git(host, args) {
  const result = command('git', ['--no-optional-locks', '-C', host, ...args], host);
  if (result.error || result.status !== 0) fail(`git ${args.join(' ')} failed: ${result.error?.message ?? result.stderr.trim()}`);
  return result.stdout;
}

function treeFiles(root, prefix = '') {
  const result = [];
  for (const entry of fs.readdirSync(path.join(root, prefix), { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    const file = safePath(root, rel);
    if (entry.isDirectory()) result.push(...treeFiles(root, rel));
    else if (entry.isFile()) result.push(rel);
    else fail(`Non-regular module entry refused: ${file}`);
  }
  return result.sort();
}

function patchPaths(text) {
  const files = [];
  const blocks = text.split(/^diff --git /m).slice(1);
  if (!blocks.length) fail('Patch has no file changes');
  for (const block of blocks) {
    const header = /^(a\/(\S+)) (b\/(\S+))\r?\n/.exec(block);
    if (!header || header[2] !== header[4]) fail('Unsupported patch path or rename');
    const name = relative(header[2]);
    const old = /^--- (.+)$/m.exec(block)?.[1];
    const next = /^\+\+\+ (.+)$/m.exec(block)?.[1];
    if ((old !== `a/${name}` && old !== '/dev/null') || next !== `b/${name}`) fail(`Unsupported patch headers: ${name}`);
    if (files.includes(name) || /^((old|new) mode|new file mode) 120000$/m.test(block)) fail(`Unsafe patch entry: ${name}`);
    files.push(name);
  }
  return files;
}

/** Read-only validation and plan. featureRoot is injectable for isolated test fixtures only. */
export function plan({ host, featureRoot = repositoryRoot } = {}) {
  if (Number(process.versions.node.split('.')[0]) < 18) fail('Node >=18 is required');
  if (typeof host !== 'string' || !path.isAbsolute(host)) fail('--host must be an absolute path');
  host = fs.realpathSync(host);
  const top = fs.realpathSync(git(host, ['rev-parse', '--show-toplevel']).trim());
  if (top !== host) fail(`Host must be the exact Git toplevel, not a subdirectory: ${top}`);
  featureRoot = fs.realpathSync(featureRoot);
  const manifestFile = safePath(featureRoot, 'Integration/host-manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  if (manifest.schema_version !== 1 || !/^[a-f0-9]{40}$/.test(manifest.commit)) fail('Unsupported manifest or pinned commit');
  const head = git(host, ['rev-parse', 'HEAD']).trim();
  if (head !== manifest.commit) fail(`Wrong HEAD: expected ${manifest.commit}, found ${head}`);
  const patch = safePath(path.join(featureRoot, 'Integration'), manifest.patch);
  if (!fs.statSync(patch).isFile()) fail(`Patch is not a regular file: ${patch}`);
  const paths = patchPaths(fs.readFileSync(patch, 'utf8'));
  const sourceRel = relative(manifest.feature_module.source);
  const destinationRel = relative(manifest.feature_module.host_destination);
  const source = safePath(featureRoot, sourceRel);
  const destination = safePath(host, destinationRel);
  if (manifest.feature_module.included_in_patch !== false) fail('Module must be installed separately from patch');
  if (source === destination || source.startsWith(`${host}${path.sep}`) || host.startsWith(`${source}${path.sep}`)) fail('Source module and host must not overlap');
  for (const name of paths) {
    safePath(host, name);
    if (name === destinationRel || name.startsWith(`${destinationRel}/`)) fail('Patch overlaps feature module destination');
  }
  const allSource = treeFiles(source);
  const files = allSource.filter(name => name === 'BUILD' || (name.startsWith('Sources/') && name.endsWith('.swift')));
  if (!files.includes('BUILD') || !files.some(name => name.endsWith('.swift'))) fail('Module requires BUILD and recursive Sources/**/*.swift');
  const dependency = `//${destinationRel}`;
  if (!fs.readFileSync(patch, 'utf8').includes(`+        "${dependency}",`)) fail(`Patch must add the module dependency ${dependency}`);
  const missing = [];
  const identical = [];
  let normalizedEofFiles = 0;
  if (exists(destination)) {
    if (!fs.statSync(destination).isDirectory()) fail(`Module destination is not a directory: ${destination}`);
    for (const name of treeFiles(destination)) if (!files.includes(name)) fail(`Unexpected existing module file (no overwrite): ${path.join(destination, name)}`);
  }
  for (const name of files) {
    const target = safePath(destination, name);
    const stat = exists(target);
    if (!stat) missing.push(name);
    else {
      if (!stat.isFile()) fail(`Different existing module file (no overwrite): ${target}`);
      const targetBytes = fs.readFileSync(target);
      const sourceBytes = fs.readFileSync(path.join(source, name));
      if (targetBytes.equals(sourceBytes)) identical.push(name);
      else if (withoutTerminalLf(targetBytes).equals(withoutTerminalLf(sourceBytes))) normalizedEofFiles++;
      else fail(`Different existing module file (no overwrite): ${target}`);
    }
  }
  const allowed = name => paths.includes(name) || name === optionalDoc || name.startsWith(`${destinationRel}/`);
  const changed = [...new Set([
    ...git(host, ['diff', '--no-ext-diff', '--name-only', '-z']).split('\0'),
    ...git(host, ['diff', '--cached', '--no-ext-diff', '--name-only', '-z']).split('\0'),
    ...git(host, ['ls-files', '--others', '--exclude-standard', '-z']).split('\0'),
  ].filter(Boolean))];
  for (const name of changed) if (!allowed(name)) fail(`Unrelated host modification refused: ${name}`);
  const forward = command('git', ['-C', host, 'apply', '--check', '--', patch], host);
  const reverse = command('git', ['-C', host, 'apply', '--reverse', '--check', '--', patch], host);
  if ((forward.status === 0) === (reverse.status === 0)) fail(`Patch state is ambiguous or incompatible; forward: ${forward.stderr}; reverse: ${reverse.stderr}`);
  const patchState = reverse.status === 0 ? 'applied' : 'unapplied';
  const versions = JSON.parse(fs.readFileSync(safePath(host, manifest.versions_source), 'utf8'));
  for (const [key, value] of Object.entries(manifest.required_versions)) {
    if (versions[key] !== value) fail(`Required host version ${key}: expected ${value}, found ${versions[key]}`);
  }
  const warnings = [];
  const xcode = command('xcodebuild', ['-version'], host);
  if (xcode.status !== 0) warnings.push(`Full Xcode ${manifest.required_versions.xcode} is required for host builds; xcodebuild is unavailable. Nothing will be installed.`);
  else if (!xcode.stdout.includes(`Xcode ${manifest.required_versions.xcode}\n`)) warnings.push(`Required Xcode ${manifest.required_versions.xcode}; found ${xcode.stdout.trim()}. Nothing will be installed.`);
  return { host, featureRoot, patch, patchState, source, destination, files, missing, identical, normalizedEofFiles, changed, warnings };
}

/** Explicit opt-in only. Revalidate instead of trusting a stale caller-supplied plan. */
export function apply({ host, featureRoot = repositoryRoot } = {}) {
  const result = plan({ host, featureRoot });
  if (result.patchState === 'unapplied' && git(result.host, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])) {
    fail('Applying an unapplied patch requires a completely clean host Git status');
  }
  const created = [];
  const directories = [];
  let appliedNow = false;
  try {
    if (result.patchState === 'unapplied') {
      git(result.host, ['apply', '--', result.patch]);
      appliedNow = true;
    }
    for (const name of result.missing) {
      const rel = path.relative(result.host, path.join(result.destination, name)).split(path.sep).join('/');
      const target = safePath(result.host, rel);
      let current = result.host;
      for (const part of path.dirname(rel).split('/')) {
        current = path.join(current, part);
        if (!exists(current)) { fs.mkdirSync(current); directories.push(current); }
        else if (fs.lstatSync(current).isSymbolicLink() || !fs.statSync(current).isDirectory()) fail(`Unsafe destination directory: ${current}`);
      }
      fs.copyFileSync(safePath(result.source, name), target, fs.constants.COPYFILE_EXCL);
      const stat = fs.lstatSync(target);
      created.push({ target, dev: stat.dev, ino: stat.ino });
    }
    return { ...result, patchState: 'applied', copied: created.length };
  } catch (error) {
    const rollbackErrors = [];
    for (const file of created.reverse()) {
      try {
        safePath(result.host, path.relative(result.host, file.target).split(path.sep).join('/'));
        const stat = exists(file.target);
        if (stat?.dev === file.dev && stat?.ino === file.ino) fs.unlinkSync(file.target);
      } catch (e) { rollbackErrors.push(e.message); }
    }
    for (const directory of directories.reverse()) {
      try { fs.rmdirSync(directory); } catch (e) { if (!['ENOENT', 'ENOTEMPTY'].includes(e.code)) rollbackErrors.push(e.message); }
    }
    fail(`${error.message}\nOnly installer-created module files were eligible for rollback. Host patch was NOT reversed${appliedNow ? ' (applied during this run)' : ''}.${rollbackErrors.length ? `\nRollback warnings: ${rollbackErrors.join('; ')}` : ''}`);
  }
}

export function parseArgs(args) {
  let host;
  let mode = 'check';
  let explicitMode = false;
  if (args.length === 1 && args[0] === '--help') return { help: true };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--host' && host === undefined) {
      host = args[++i];
      if (!host || !path.isAbsolute(host)) fail('--host must be an absolute path');
    } else if ((arg === '--check' || arg === '--apply') && !explicitMode) {
      mode = arg.slice(2); explicitMode = true;
    } else fail(`Unknown, duplicate, or conflicting argument: ${arg}`);
  }
  if (!host) fail('--host ABS is required (use --help)');
  return { host, mode };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: node Scripts/integrate-telegram.mjs --host ABS [--check|--apply]\nDefault: --check (read-only). --help shows this message.\nRequires Node >=18 and Git. No signing, downloads, installation, or host builds.');
    return;
  }
  const result = args.mode === 'apply' ? apply(args) : plan(args);
  console.log(`${args.mode === 'check' ? 'READ-ONLY CHECK' : 'APPLY COMPLETE'}\nHost: ${result.host}\nPatch: ${result.patchState}\nModule destination: ${result.destination}\nModule files: ${result.files.length}; identical: ${result.identical.length}; normalizedEofFiles: ${result.normalizedEofFiles}; missing: ${result.missing.length}`);
  if (result.normalizedEofFiles) console.log('normalizedEofFiles counts non-byte-identical matches differing only in terminal LF bytes; existing files are left unchanged.');
  for (const name of result.missing) console.log(`${args.mode === 'check' ? 'Would copy' : 'Copied'}: ${name}`);
  if (args.mode === 'check' && result.patchState === 'unapplied') console.log('Would apply host patch; --apply requires a completely clean host Git status.');
  for (const warning of result.warnings) console.warn(`WARNING: ${warning}`);
  if (args.mode === 'check') console.log('No files changed. No build, signing, or network operations performed.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(`ERROR: ${error.message}`); process.exitCode = 1; }
}