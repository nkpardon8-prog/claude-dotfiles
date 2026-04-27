#!/usr/bin/env node
// grant-cdp-permissions.mjs — call CDP Browser.grantPermissions via debug port
// Requires: Node 18+ (built-in WebSocket + fetch + top-level await in .mjs)
// Requires: Chrome started with --remote-debugging-port=9222
//
// Usage: node grant-cdp-permissions.mjs --origin URL --permissions p1,p2,p3 [--port 9222]
//
// Note: keyboardLock requires Chrome >= 131. If the running Chrome is older, this
// script silently drops keyboardLock from the request (and prints a warning) so
// the clipboard grants don't fail atomically.

const args = process.argv.slice(2);
const opts = {origin: null, permissions: null, port: 9222};
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--origin') opts.origin = args[++i];
  else if (args[i] === '--permissions') opts.permissions = args[++i];
  else if (args[i] === '--port') opts.port = parseInt(args[++i], 10);
}

if (!opts.origin || !opts.permissions) {
  console.error('Usage: --origin URL --permissions p1,p2,p3 [--port 9222]');
  process.exit(1);
}

let perms = opts.permissions.split(',').map(s => s.trim()).filter(Boolean);
const versionUrl = `http://127.0.0.1:${opts.port}/json/version`;

let wsUrl;
let chromeMajor = null;
try {
  const resp = await fetch(versionUrl);
  if (!resp.ok) {
    console.error(`Chrome debug port ${opts.port} not reachable (HTTP ${resp.status})`);
    process.exit(2);
  }
  const json = await resp.json();
  wsUrl = json.webSocketDebuggerUrl;
  if (!wsUrl) {
    console.error('No webSocketDebuggerUrl in /json/version response');
    process.exit(3);
  }
  // Parse "Browser": "Chrome/131.0.6778.86" → 131
  const browserField = json.Browser || '';
  const m = browserField.match(/Chrome\/(\d+)\./);
  if (m) chromeMajor = parseInt(m[1], 10);
} catch (err) {
  console.error(`Cannot reach Chrome at port ${opts.port}: ${err.message}`);
  console.error('Fix: launch Chrome with --remote-debugging-port=9222');
  process.exit(2);
}

// keyboardLock is only known to CDP on Chrome >= 131. If the request
// includes it on older Chrome, the entire grant call fails atomically,
// taking clipboard grants down with it. Drop it preemptively and warn.
if (perms.includes('keyboardLock')) {
  if (chromeMajor === null) {
    console.warn('WARN: cannot detect Chrome major version; sending keyboardLock as requested.');
  } else if (chromeMajor < 131) {
    console.warn(`WARN: Chrome ${chromeMajor} does not support keyboardLock (needs >=131). Skipping keyboardLock; clipboard grants will still proceed.`);
    perms = perms.filter(p => p !== 'keyboardLock');
  }
}

if (perms.length === 0) {
  console.error('ERROR: no permissions left to grant after version filtering');
  process.exit(4);
}

const ws = new WebSocket(wsUrl);
const result = await new Promise((resolve, reject) => {
  let timeoutId = null;
  const cleanup = () => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
  };
  ws.onopen = () => {
    ws.send(JSON.stringify({
      id: 1,
      method: 'Browser.grantPermissions',
      params: {origin: opts.origin, permissions: perms}
    }));
  };
  ws.onmessage = (event) => {
    let reply;
    try {
      reply = JSON.parse(event.data);
    } catch (e) {
      // Ignore malformed frames; CDP shouldn't send them, but skip rather than throw.
      return;
    }
    if (reply.id === 1) {
      cleanup();
      ws.close();
      if (reply.error) reject(new Error(JSON.stringify(reply.error)));
      else resolve(reply.result);
    }
  };
  ws.onerror = (err) => {
    cleanup();
    reject(err);
  };
  timeoutId = setTimeout(() => {
    timeoutId = null;
    reject(new Error('timeout after 5s'));
  }, 5000);
});

console.log(`OK: granted [${perms.join(', ')}] on ${opts.origin}`);
process.exit(0);
