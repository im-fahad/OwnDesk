// Static server for the harness. Usage: node tools/web-harness/serve.js [--port 8080] [--host 0.0.0.0]
// The harness is a development tool: it holds an extractable key in localStorage. Never ship it.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : fallback; };
const port = Number(opt('--port', '8080'));
const host = opt('--host', '127.0.0.1');
const root = import.meta.dirname;
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };

createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '');
  const file = join(root, path === '/' ? 'index.html' : path);
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
  } catch {
    res.writeHead(404); res.end('not found');
  }
}).listen(port, host, () => {
  console.log(`PRC web harness at http://${host}:${port}/`);
  console.log('Open it in Safari or Chrome on the LAN. Use --host 0.0.0.0 to reach it from another machine.');
});
