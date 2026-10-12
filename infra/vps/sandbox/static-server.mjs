// 沙盒内辅助 HTTP 服务(只在内网 docker_play 上暴露,由边缘 Caddy 转发)。
//
// 为什么需要它:opencode 自己不会把 /workspace 当静态网站提供,而访客要「实时看到自己
// 做的网站」;同时 opencode 的 /config 会把解析后的网关密钥原样吐出来,不能直接给访客。
// 三件事都在这里做:
//
//   GET /__hub              → 工作台页(hub.html,注入会话 id)
//   GET /__config           → 真实 /config 的净化副本(去掉 provider 块:内含网关密钥)
//   GET /__gconfig          → 同上,对应 /global/config
//   GET /preview/<path>     → 只读静态文件,根 = /workspace,不列目录、无目录穿越
//
// 只用 node 内置模块,无依赖;node 是官方 opencode 镜像自带的运行时。
import { createServer } from "node:http";
import { stat, readFile } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { extname, join, resolve, sep } from "node:path";

const PORT = Number(process.env.SANDBOX_HELPER_PORT || 4173);
const WORKSPACE = "/workspace";
const HUB_FILE = "/srv/hub.html";
const SESSION_ID = process.env.PLAYGROUND_SESSION_ID || "ses_guest";
const UPSTREAM = process.env.SANDBOX_UPSTREAM || "http://127.0.0.1:4096";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".wasm": "application/wasm",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".pdf": "application/pdf",
};

const baseHeaders = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" };
const send = (res, status, body, headers = {}) => {
  res.writeHead(status, { ...baseHeaders, ...headers });
  res.end(body);
};
const notFound = (res) => send(res, 404, "not found", { "Content-Type": "text/plain; charset=utf-8" });
// 预览根还没 index.html 时的友好提示(右栏不显示裸 404)
const PREVIEW_HINT =
  '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>访客的网站</title>' +
  '<body style="font:14px/1.7 system-ui,sans-serif;padding:2.5rem;color:#52525b">' +
  "<h2 style=\"font-size:16px;font-weight:600;margin:0 0 .6rem;color:#18181b\">还没有网页</h2>" +
  "<p>在左侧会话里让助手创建 <code>index.html</code>(或直接丢个 HTML 进去),保存后这里会实时刷新。</p></body></html>";

// opencode 可能比本服务晚就绪(同一容器内并发启动),取上游时重试几次。
async function upstream(path, tries = 5) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      return await fetch(UPSTREAM + path, { headers: { accept: "application/json" } });
    } catch (err) {
      lastErr = err;
      await new Promise((r) => setTimeout(r, 300));
    }
  }
  throw lastErr;
}

// 净化:去掉 provider(里面是 options.apiKey / baseURL)。其余字段原样透传,避免与
// 镜像里的 opencode.json 失同步。
async function serveSanitizedConfig(res, upstreamPath, search) {
  let body;
  try {
    const r = await upstream(upstreamPath + (search || ""));
    if (!r.ok) return send(res, r.status, "config unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "config unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  delete body.provider;
  return send(res, 200, JSON.stringify(body), { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
}

async function serveHub(req, res) {
  let html;
  try {
    html = (await readFile(HUB_FILE, "utf8")).replaceAll("__SESSION_ID__", SESSION_ID);
  } catch {
    return send(res, 500, "hub unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(req.method === "HEAD" ? undefined : html);
}

async function serveFile(req, res, file) {
  let st;
  try {
    st = await stat(file);
  } catch {
    return notFound(res);
  }
  if (!st.isFile()) return notFound(res);
  res.writeHead(200, {
    ...baseHeaders,
    "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
    "Content-Length": st.size,
    "Last-Modified": st.mtime.toUTCString(),
    "Cache-Control": "no-store",
  });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

async function servePreview(req, res, pathname) {
  let rel = pathname.replace(/^\/preview\/?/, "");
  try {
    rel = decodeURIComponent(rel);
  } catch {
    return send(res, 400, "bad path");
  }
  if (rel.includes("\0")) return send(res, 400, "bad path");
  const target = resolve(join(WORKSPACE, rel));
  if (target !== WORKSPACE && !target.startsWith(WORKSPACE + sep)) return send(res, 403, "forbidden");
  let st;
  try {
    st = await stat(target);
  } catch {
    return notFound(res);
  }
  if (st.isDirectory()) {
    // 不列目录:有 index.html 才回;根目录还没有网页时给中文提示(右栏不显示裸 404)
    const idx = join(target, "index.html");
    let st2;
    try {
      st2 = await stat(idx);
    } catch {
      if (pathname === "/preview" || pathname === "/preview/") {
        return send(res, 200, PREVIEW_HINT, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      }
      return notFound(res);
    }
    return serveFile(req, res, idx);
  }
  return serveFile(req, res, target);
}

const server = createServer(async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "method not allowed");
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname;

  if (pathname === "/__hub") return serveHub(req, res);
  if (pathname === "/__config") return serveSanitizedConfig(res, "/config", url.search);
  if (pathname === "/__gconfig") return serveSanitizedConfig(res, "/global/config", url.search);
  if (pathname === "/__preview-health") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  if (pathname === "/preview" || pathname.startsWith("/preview/")) return servePreview(req, res, pathname);
  return notFound(res);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[sandbox-helper] listening on :${PORT} (workspace=${WORKSPACE}, session=${SESSION_ID})`);
});
