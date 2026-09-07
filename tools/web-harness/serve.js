// Static server for the harness.
//   node tools/web-harness/serve.js               localhost only
//   node tools/web-harness/serve.js --host 0.0.0.0  reachable from other machines on the LAN
// The harness is a development tool: it holds a raw private key in localStorage. Never ship it.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { existsSync } from 'node:fs';

const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : fallback; };
const port = Number(opt('--port', '8080'));
const host = opt('--host', '127.0.0.1');
const root = import.meta.dirname;
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json' };

// node_modules may be hoisted to the repository root by npm workspaces; find the nearest one.
function findNodeModules(from) {
  let dir = resolve(from);
  while (true) {
    const candidate = join(dir, 'node_modules');
    if (existsSync(join(candidate, '@noble'))) return candidate;
    const parent = dirname(dir);
    if (parent === dir) throw new Error('node_modules with @noble not found; run npm install at the repo root');
    dir = parent;
  }
}
const nodeModules = findNodeModules(root);

function fileFor(pathname) {
  const clean = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, '');
  if (clean.startsWith('/vendor/')) return join(nodeModules, clean.slice('/vendor/'.length));
  return join(root, clean === '/' ? 'index.html' : clean);
}

createServer(async (req, res) => {
  try {
    const file = fileFor(new URL(req.url, 'http://x').pathname);
    if (!(file.startsWith(root) || file.startsWith(nodeModules))) throw new Error('outside root');
    if (!(await stat(file)).isFile()) throw new Error('not a file');
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
}).listen(port, host, () => {
  const urls = [];
  if (host === '0.0.0.0' || host === '::') {
    for (const list of Object.values(networkInterfaces())) {
      for (const i of list) if (i.family === 'IPv4' && !i.internal) urls.push(`http://${i.address}:${port}/`);
    }
    urls.push(`http://127.0.0.1:${port}/`);
  } else {
    urls.push(`http://${host}:${port}/`);
  }
  console.log('PRC web harness is listening. Open one of these in Safari or Chrome:');
  for (const u of urls) console.log(`  ${u}`);
  if (host !== '0.0.0.0' && host !== '::') console.log('Other machines cannot reach it. Restart with --host 0.0.0.0 to allow that.');
  else console.log('From another machine use the LAN address above, never 0.0.0.0. If nothing loads, allow node in System Settings > Network > Firewall.');
});
