#!/usr/bin/env node
// check-cdp-permission.mjs — read current grant state via CDP
// Returns one of: granted | denied | prompt | unknown
// Used by /macmini auto-grant install to detect prior UI-denial conflicts.

const args = process.argv.slice(2);
const opts = {origin: null, permission: null, port: 9222};
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--origin') opts.origin = args[++i];
  else if (args[i] === '--permission') opts.permission = args[++i];
  else if (args[i] === '--port') opts.port = parseInt(args[++i], 10);
}

if (!opts.origin || !opts.permission) {
  console.error('Usage: --origin URL --permission clipboard-read');
  process.exit(1);
}

let wsUrl;
try {
  const resp = await fetch(`http://127.0.0.1:${opts.port}/json/version`);
  wsUrl = (await resp.json()).webSocketDebuggerUrl;
} catch {
  console.log('unreachable');
  process.exit(0);
}

const ws = new WebSocket(wsUrl);
const result = await new Promise((resolve) => {
  ws.onopen = () => {
    // CDP Browser.getPermission requires Permissions.PermissionDescriptor
    ws.send(JSON.stringify({
      id: 1,
      method: 'Browser.getPermission',
      params: {origin: opts.origin, permission: {name: opts.permission}}
    }));
  };
  ws.onmessage = (event) => {
    const reply = JSON.parse(event.data);
    if (reply.id === 1) {
      ws.close();
      if (reply.error) resolve('unknown');
      else resolve(reply.result?.state || 'unknown');
    }
  };
  ws.onerror = () => resolve('unknown');
  setTimeout(() => resolve('unknown'), 3000);
});

console.log(result);
process.exit(0);
