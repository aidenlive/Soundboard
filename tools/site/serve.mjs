#!/usr/bin/env node
// Serves public/ for local preview. No dependencies.
//   node tools/site/serve.mjs        http://localhost:8052/
// SITE_ROOT, SITE_PORT and SITE_HOST override the folder, port (8052) and host (127.0.0.1).

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(process.env.SITE_ROOT || path.join(here, "../../public"));
const port = Number(process.env.SITE_PORT || 8052);
const host = process.env.SITE_HOST || "127.0.0.1";
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png",
  ".json": "application/json", ".txt": "text/plain; charset=utf-8", ".md": "text/markdown; charset=utf-8", ".ttf": "font/ttf" };

http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (p.endsWith("/")) p += "index.html";
  const file = path.resolve(root, `.${p}`);
  if (!file.startsWith(root + path.sep) && file !== root) { res.writeHead(403).end(); return; }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { "content-type": "text/plain" }).end("not found"); return; }
    res.writeHead(200, { "content-type": types[path.extname(file)] || "application/octet-stream" }).end(data);
  });
}).listen(port, host, () => console.log(`serving ${root} at http://${host === "0.0.0.0" ? "localhost" : host}:${port}/`));
