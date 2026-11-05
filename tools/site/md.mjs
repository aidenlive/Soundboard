// Minimal Markdown → HTML for this repository's docs. No dependencies.
// Supports: ATX headings (with ids), paragraphs, fenced code, tables, blockquotes, hr,
// nested ordered/unordered lists, and inline code, strong, em, links, images, <autolinks>.
// `link(href)` lets the caller rewrite or drop each link: return a string (new href) or null
// (render the text as code, for repository files with no page).

export function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/&[a-z]+;/g, "")
    .replace(/[`*_~]/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .trim()
    .replace(/\s+/g, "-");
}

function inline(text, opts) {
  const codes = [];
  let s = text.replace(/`([^`]+)`/g, (_, c) => {
    codes.push(`<code>${escapeHtml(c)}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = escapeHtml(s);
  // images, then links
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_, alt, href) => {
    const h = opts.asset ? opts.asset(href) : href;
    return h ? `<img src="${h}" alt="${alt}" loading="lazy">` : `<code>${escapeHtml(href)}</code>`;
  });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) => {
    const h = opts.link ? opts.link(href.replace(/&amp;/g, "&")) : href;
    if (h === null) return `<code>${label.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[+i].replace(/^<code>|<\/code>$/g, ""))}</code>`;
    const ext = /^https?:/.test(h) ? ' rel="noopener"' : "";
    return `<a href="${escapeHtml(h)}"${ext}>${label}</a>`;
  });
  s = s.replace(/&lt;(https?:\/\/[^\s&]+)&gt;/g, (_, u) => `<a href="${u}" rel="noopener">${u}</a>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^\w*])\*([^*\s][^*]*?)\*(?!\w)/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^\w])_([^_\s][^_]*?)_(?!\w)/g, "$1<em>$2</em>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[+i]);
}

function splitRow(line) {
  let l = line.trim();
  if (l.startsWith("|")) l = l.slice(1);
  if (l.endsWith("|")) l = l.slice(0, -1);
  const cells = [];
  let cur = "", tick = false;
  for (const ch of l) {
    if (ch === "`") tick = !tick;
    if (ch === "|" && !tick) { cells.push(cur.trim()); cur = ""; } else cur += ch;
  }
  cells.push(cur.trim());
  return cells;
}

const listRe = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;

function renderList(lines, start, opts) {
  // Returns [html, nextIndex]. Items at the indentation of lines[start].
  const first = lines[start].match(listRe);
  const indent = first[1].length;
  const ordered = /\d/.test(first[2]);
  const items = [];
  let i = start;
  while (i < lines.length) {
    const m = lines[i].match(listRe);
    if (!m || m[1].length !== indent || /\d/.test(m[2]) !== ordered) {
      if (m && m[1].length > indent && items.length) {
        const [html, next] = renderList(lines, i, opts);
        items[items.length - 1].children += html;
        i = next;
        continue;
      }
      if (!m && lines[i].trim() && /^\s+/.test(lines[i]) && items.length && lines[i].match(/^\s*/)[0].length > indent) {
        items[items.length - 1].text += " " + lines[i].trim();
        i++;
        continue;
      }
      break;
    }
    items.push({ text: m[3], children: "" });
    i++;
  }
  const tag = ordered ? "ol" : "ul";
  return [`<${tag}>${items.map((it) => `<li>${inline(it.text, opts)}${it.children}</li>`).join("")}</${tag}>`, i];
}

export function render(md, opts = {}) {
  const lines = md.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  const headings = [];
  const used = new Map();
  let i = 0;
  let para = [];
  const flush = () => {
    if (para.length) out.push(`<p>${inline(para.join(" "), opts)}</p>`);
    para = [];
  };
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^(\s*)(```+|~~~+)\s*([\w-]*)\s*$/);
    if (fence) {
      flush();
      const close = fence[2];
      const body = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(close)) body.push(lines[i++].slice(fence[1].length));
      i++;
      const lang = fence[3] ? ` class="language-${fence[3]}"` : "";
      out.push(`<pre><code${lang}>${escapeHtml(body.join("\n"))}</code></pre>`);
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/);
    if (h) {
      flush();
      const level = h[1].length;
      const html = inline(h[2], opts);
      let id = slugify(h[2]) || "section";
      const n = used.get(id) || 0;
      used.set(id, n + 1);
      if (n) id = `${id}-${n}`;
      headings.push({ level, id, text: html.replace(/<[^>]+>/g, "") });
      out.push(`<h${level} id="${id}">${html}</h${level}>`);
      i++;
      continue;
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push("<hr>"); i++; continue; }
    if (line.trim().startsWith("|") && i + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) {
      flush();
      const head = splitRow(line);
      const align = splitRow(lines[i + 1]).map((c) => (c.endsWith(":") ? (c.startsWith(":") ? "center" : "right") : ""));
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith("|")) rows.push(splitRow(lines[i++]));
      const cell = (tag, c, k) => `<${tag}${align[k] ? ` style="text-align:${align[k]}"` : ""}>${inline(c, opts)}</${tag}>`;
      out.push(`<div class="table"><table><thead><tr>${head.map((c, k) => cell("th", c, k)).join("")}</tr></thead><tbody>` +
        rows.map((r) => `<tr>${r.map((c, k) => cell("td", c, k)).join("")}</tr>`).join("") + "</tbody></table></div>");
      continue;
    }
    if (line.startsWith(">")) {
      flush();
      const body = [];
      while (i < lines.length && lines[i].startsWith(">")) body.push(lines[i++].replace(/^>\s?/, ""));
      out.push(`<blockquote>${render(body.join("\n"), opts).html}</blockquote>`);
      continue;
    }
    if (listRe.test(line) && !/^\s{4,}/.test(line)) {
      flush();
      const [html, next] = renderList(lines, i, opts);
      out.push(html);
      i = next;
      continue;
    }
    if (!line.trim()) { flush(); i++; continue; }
    para.push(line.trim());
    i++;
  }
  flush();
  return { html: out.join("\n"), headings };
}
