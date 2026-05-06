#!/usr/bin/env bash
# Scaffolds an Express + 4 callback-style helper modules. The /dual-build (or
# baseline) run must migrate all four modules to async/await while preserving
# subtle behaviors that mechanical promisify misses:
#
# - cache.js:    cache miss on expired key returns (null, null), not an error.
# - file-ops.js: ENOENT on readJSON returns defaults, not an error; atomicWrite
#                must clean up the tmp file on rename failure.
# - http-fetch.js: 'error' event AND timeout can both fire; the timer must be
#                  cleared on success to avoid leaks.
# - job-queue.js: cancel() flag must be checked between iterations; first-error
#                 must halt with that error.
#
# Each module is file-disjoint. ~50 LOC each, ~200 LOC total. Tests pin the
# basic contracts; subtle gotchas are designed to live below the test surface
# so cross-review can earn its keep.
set -euo pipefail

sandbox="${1:?sandbox path required}"
rm -rf "$sandbox"
mkdir -p "$sandbox"
cd "$sandbox"

git init -q -b main
git config user.email "test@example.com"
git config user.name "test"

npm init -y -q >/dev/null
npm pkg set type=module >/dev/null

mkdir -p lib test

# ----------------------------------------------------------------------------
# T1: lib/cache.js — in-memory TTL cache, callback API
# ----------------------------------------------------------------------------
cat > lib/cache.js <<'EOF'
// In-memory TTL cache. Callback-style API: cb(err, result).
//
// Contract notes:
// - get(key, cb): if key missing OR expired, cb(null, null) — NOT an error.
// - set(key, val, ttlMs, cb): stores val with an expiry timer.
// - invalidate(key, cb): removes key and clears its expiry timer.
//
// Migrate to async/await while preserving these contracts.

const store = new Map();   // key -> { val, expiresAt }
const timers = new Map();  // key -> Timeout (so invalidate() can clear)

export function get(key, cb) {
  setImmediate(() => {
    const entry = store.get(key);
    if (!entry) return cb(null, null);
    if (entry.expiresAt <= Date.now()) {
      store.delete(key);
      return cb(null, null);
    }
    cb(null, entry.val);
  });
}

export function set(key, val, ttlMs, cb) {
  setImmediate(() => {
    if (typeof key !== 'string') return cb(new Error('key must be string'));
    if (typeof ttlMs !== 'number' || ttlMs <= 0) {
      return cb(new Error('ttlMs must be positive number'));
    }
    const prev = timers.get(key);
    if (prev) clearTimeout(prev);
    store.set(key, { val, expiresAt: Date.now() + ttlMs });
    const t = setTimeout(() => {
      store.delete(key);
      timers.delete(key);
    }, ttlMs);
    if (typeof t.unref === 'function') t.unref();
    timers.set(key, t);
    cb(null);
  });
}

export function invalidate(key, cb) {
  setImmediate(() => {
    const t = timers.get(key);
    if (t) clearTimeout(t);
    timers.delete(key);
    store.delete(key);
    cb(null);
  });
}
EOF

# ----------------------------------------------------------------------------
# T2: lib/file-ops.js — JSON file I/O + atomic write, callback API
# ----------------------------------------------------------------------------
cat > lib/file-ops.js <<'EOF'
// JSON file I/O with atomic-write semantics. Callback-style API.
//
// Contract notes:
// - readJSON(path, defaults, cb): if file missing (ENOENT), cb(null, defaults).
//   Other errors propagate normally.
// - writeJSON(path, data, cb): plain write. JSON.stringify with 2-space indent.
// - atomicWrite(path, data, cb): writes to <path>.tmp then renames. If rename
//   fails, the tmp file MUST be unlinked (no leaked tmp files on disk).
//
// Migrate to async/await while preserving these contracts.

import fs from 'node:fs';

export function readJSON(path, defaults, cb) {
  fs.readFile(path, 'utf8', (err, raw) => {
    if (err) {
      if (err.code === 'ENOENT') return cb(null, defaults);
      return cb(err);
    }
    try {
      cb(null, JSON.parse(raw));
    } catch (e) {
      cb(e);
    }
  });
}

export function writeJSON(path, data, cb) {
  let raw;
  try {
    raw = JSON.stringify(data, null, 2);
  } catch (e) {
    return cb(e);
  }
  fs.writeFile(path, raw, 'utf8', cb);
}

export function atomicWrite(path, data, cb) {
  const tmp = path + '.tmp';
  let raw;
  try {
    raw = JSON.stringify(data, null, 2);
  } catch (e) {
    return cb(e);
  }
  fs.writeFile(tmp, raw, 'utf8', (writeErr) => {
    if (writeErr) return cb(writeErr);
    fs.rename(tmp, path, (renameErr) => {
      if (renameErr) {
        // Cleanup tmp on rename failure. Don't let the unlink error mask the
        // real (rename) error.
        fs.unlink(tmp, () => cb(renameErr));
        return;
      }
      cb(null);
    });
  });
}
EOF

# ----------------------------------------------------------------------------
# T3: lib/http-fetch.js — HTTP JSON GET with timeout, callback API
# ----------------------------------------------------------------------------
cat > lib/http-fetch.js <<'EOF'
// HTTP JSON GET with explicit timeout. Callback-style API.
//
// Contract notes:
// - fetchJSON(url, opts, cb): GETs the URL, parses body as JSON.
//   opts.timeoutMs: required, > 0. On timeout, cb(Error('timeout')) and the
//   request is destroyed.
// - The 'error' event AND the timeout can both fire (network error during
//   the timeout window). The callback MUST be invoked AT MOST ONCE.
// - The timeout timer MUST be cleared on success to avoid leaking timers
//   into the event loop.
//
// Migrate to async/await while preserving the at-most-once and
// no-leaked-timer contracts.

import http from 'node:http';
import https from 'node:https';
import { URL } from 'node:url';

export function fetchJSON(url, opts, cb) {
  if (!opts || typeof opts.timeoutMs !== 'number' || opts.timeoutMs <= 0) {
    return cb(new Error('opts.timeoutMs must be positive number'));
  }

  let done = false;
  const finish = (err, val) => {
    if (done) return;
    done = true;
    cb(err, val);
  };

  let parsed;
  try {
    parsed = new URL(url);
  } catch (e) {
    return finish(e);
  }
  const lib = parsed.protocol === 'https:' ? https : http;

  const req = lib.get(url, (res) => {
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => { body += chunk; });
    res.on('end', () => {
      clearTimeout(timer);
      try {
        finish(null, JSON.parse(body));
      } catch (e) {
        finish(e);
      }
    });
    res.on('error', (err) => {
      clearTimeout(timer);
      finish(err);
    });
  });

  req.on('error', (err) => {
    clearTimeout(timer);
    finish(err);
  });

  const timer = setTimeout(() => {
    req.destroy(new Error('timeout'));
    finish(new Error('timeout'));
  }, opts.timeoutMs);
}
EOF

# ----------------------------------------------------------------------------
# T4: lib/job-queue.js — sequential job runner with cancel, callback API
# ----------------------------------------------------------------------------
cat > lib/job-queue.js <<'EOF'
// Runs an array of async jobs in SERIES. Callback-style API.
//
// Each job is a function (cb) => void; cb(err, result) on completion.
//
// Contract notes:
// - run(jobs, cb): runs jobs in order. If any job errors, halts and cb(err).
//   On success, cb(null, results[]) where results are job return values
//   in original order.
// - cancel(): subsequent jobs are skipped. The current in-flight job runs
//   to completion; cb(Error('cancelled')) is invoked AFTER the in-flight
//   job's callback returns.
// - run([], cb): cb(null, []) — empty input is success with empty results.
//
// Migrate to async/await while preserving series order, halt-on-error, and
// the cancel-between-iterations behavior. Empty input must still produce
// (null, []).

export function makeQueue() {
  let cancelled = false;
  return {
    cancel() { cancelled = true; },
    run(jobs, cb) {
      if (!Array.isArray(jobs)) {
        return cb(new Error('jobs must be an array'));
      }
      const results = [];
      let i = 0;
      const next = () => {
        if (cancelled) return cb(new Error('cancelled'));
        if (i >= jobs.length) return cb(null, results);
        const job = jobs[i++];
        job((err, result) => {
          if (err) return cb(err);
          results.push(result);
          next();
        });
      };
      next();
    },
  };
}
EOF

# ----------------------------------------------------------------------------
# Existing baseline tests — these MUST keep passing post-migration.
# Builders may add more tests; these are the contract.
# ----------------------------------------------------------------------------
cat > test/baseline.test.js <<'EOF'
// Baseline contract tests. These test against the CALLBACK API and run
// pre-migration. The acceptance script re-runs the migrated test file
// (which builders write) post-migration; it does NOT re-run this file
// (the API has changed by then).
//
// Builders are expected to add their own *.test.js or test/*.test.js files
// that exercise the migrated async API and the same contracts.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { get, set, invalidate } from '../lib/cache.js';
import { readJSON, atomicWrite } from '../lib/file-ops.js';
import { makeQueue } from '../lib/job-queue.js';

test('cache: missing key returns null, not error', (_, done) => {
  get('does-not-exist', (err, val) => {
    assert.equal(err, null);
    assert.equal(val, null);
    done();
  });
});

test('cache: set then get returns value', (_, done) => {
  set('k1', 42, 1000, (err) => {
    assert.equal(err, null);
    get('k1', (err2, val) => {
      assert.equal(err2, null);
      assert.equal(val, 42);
      done();
    });
  });
});

test('cache: invalidate removes value', (_, done) => {
  set('k2', 'hello', 5000, () => {
    invalidate('k2', () => {
      get('k2', (err, val) => {
        assert.equal(err, null);
        assert.equal(val, null);
        done();
      });
    });
  });
});

test('file-ops: readJSON on missing file returns defaults', (_, done) => {
  const p = path.join(os.tmpdir(), 'no-such-file-' + Date.now() + '.json');
  readJSON(p, { fallback: true }, (err, val) => {
    assert.equal(err, null);
    assert.deepEqual(val, { fallback: true });
    done();
  });
});

test('file-ops: atomicWrite then read round-trips', (_, done) => {
  const p = path.join(os.tmpdir(), 'aw-' + Date.now() + '.json');
  atomicWrite(p, { v: 1 }, (err) => {
    assert.equal(err, null);
    readJSON(p, {}, (err2, val) => {
      assert.equal(err2, null);
      assert.deepEqual(val, { v: 1 });
      fs.unlinkSync(p);
      done();
    });
  });
});

test('job-queue: empty jobs => (null, [])', (_, done) => {
  const q = makeQueue();
  q.run([], (err, results) => {
    assert.equal(err, null);
    assert.deepEqual(results, []);
    done();
  });
});

test('job-queue: runs in series and collects results', (_, done) => {
  const q = makeQueue();
  const order = [];
  const j = (n) => (cb) => {
    order.push('start-' + n);
    setImmediate(() => { order.push('end-' + n); cb(null, n * 10); });
  };
  q.run([j(1), j(2), j(3)], (err, results) => {
    assert.equal(err, null);
    assert.deepEqual(results, [10, 20, 30]);
    assert.deepEqual(order, ['start-1', 'end-1', 'start-2', 'end-2', 'start-3', 'end-3']);
    done();
  });
});

test('job-queue: halts on first error', (_, done) => {
  const q = makeQueue();
  const ok = (cb) => setImmediate(() => cb(null, 'ok'));
  const bad = (cb) => setImmediate(() => cb(new Error('boom')));
  q.run([ok, bad, ok], (err, results) => {
    assert.equal(err.message, 'boom');
    assert.equal(results, undefined);
    done();
  });
});
EOF

# ----------------------------------------------------------------------------
# Minimal package.json scripts
# ----------------------------------------------------------------------------
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json'));
pkg.scripts = pkg.scripts || {};
pkg.scripts.test = 'node --test';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"

git add .
git commit -qm "initial: 4 callback-style modules + baseline contract tests"

echo "Scaffolded callback-async-migration project at $sandbox"
