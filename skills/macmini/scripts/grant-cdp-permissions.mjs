#!/usr/bin/env node
// grant-cdp-permissions.mjs — call CDP Browser.grantPermissions via debug port
// Requires: Node 18+ (built-in WebSocket + fetch + top-level await in .mjs)
// Requires: Chrome started with --remote-debugging-port=9222
//
// Usage: node grant-cdp-permissions.mjs --origin URL --permissions p1,p2,p3 [--port 9222]

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

const perms = opts.permissions.split(',').map(s => s.trim());
const versionUrl = `http://127.0.0.1:${opts.port}/json/version`;

let wsUrl;
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
} catch (err) {
  console.error(`Cannot reach Chrome at port ${opts.port}: ${err.message}`);
  console.error('Fix: launch Chrome with --remote-debugging-port=9222');
  process.exit(2);
}

const ws = new WebSocket(wsUrl);
const result = await new Promise((resolve, reject) => {
  ws.onopen = () => {
    ws.send(JSON.stringify({
      id: 1,
      method: 'Browser.grantPermissions',
      params: {origin: opts.origin, permissions: perms}
    }));
  };
  ws.onmessage = (event) => {
    const reply = JSON.parse(event.data);
    if (reply.id === 1) {
      ws.close();
      if (reply.error) reject(new Error(JSON.stringify(reply.error)));
      else resolve(reply.result);
    }
  };
  ws.onerror = (err) => reject(err);
  setTimeout(() => reject(new Error('timeout after 5s')), 5000);
});

console.log(`OK: granted [${perms.join(', ')}] on ${opts.origin}`);
process.exit(0);
