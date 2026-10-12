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
import { createServer, request as httpRequest } from "node:http";
import { stat, readFile } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { connect as netConnect } from "node:net";

const PORT = Number(process.env.SANDBOX_HELPER_PORT || 47311);
const WORKSPACE = "/workspace";
const HUB_FILE = "/srv/hub.html";
const SESSION_ID = process.env.PLAYGROUND_SESSION_ID || "ses_guest";
const UPSTREAM = process.env.SANDBOX_UPSTREAM || "http://127.0.0.1:4096";
// 访客应用的**约定后端端口**:预览里的非静态请求(如 /api/*)会反代到它。
const APP_PORT = Number(process.env.SANDBOX_APP_PORT || 8000);

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

// ---------- 会话外壳(/__shell):取回 opencode 的 index.html 并注入外壳代码后一次性返回 ----------
// 过去是「外壳页 + 同步 XHR 拉 /__shell + document.write」,会阻塞一拍且晚发现 bundle;
// 现在由本服务在服务端注入后直接返回终态 HTML,浏览器拿到即解析、立刻并行下载 bundle/CSS。
// 外壳客户端代码/样式原先内联在 Caddyfile 里,现集中到这里(单一来源、便于维护)。
const SHELL_CSS = [
  'header,aside,[data-slot=user-message-meta],[data-slot=text-part-meta],button[data-action=prompt-model],button:has(svg[data-component=provider-icon]){display:none!important}',
  '[class*="md:max-w-200"],[class*="2xl:max-w-[1000px]"]{max-width:none!important}',
  '[data-zx-ag]{display:inline-flex;gap:4px;margin:0 2px;padding:2px;align-items:center}',
  '[data-zx-ag] button{font:12px/1.2 system-ui;color:inherit;background:transparent;border:1px solid rgba(128,128,128,.4);border-radius:999px;padding:2px 10px;cursor:pointer}',
  '[data-zx-ag] button.on{background:#3574f0;border-color:#3574f0;color:#fff}',
  'div[class*="h-[240px]"][class*="w-[192px]"]{display:none!important}',
  '[data-sonner-toaster],[data-sonner-toast]{display:none!important}',
  '[data-component="session-turn"]{content-visibility:auto;contain-intrinsic-size:auto 320px}',
].join("");

const SHELL_CLIENT = `(function(){
var S=JSON.stringify(location.pathname.replace(/\\/+$/,""));
var AG="zx-sandbox-agent";
try{var RK="settings.v3",rw=localStorage.getItem(RK),ro=rw?JSON.parse(rw):{};ro=(ro&&typeof ro==="object")?ro:{};ro.general=(ro.general&&typeof ro.general==="object")?ro.general:{};if(ro.general.showReasoningSummaries!==true){ro.general.showReasoningSummaries=true;localStorage.setItem(RK,JSON.stringify(ro));}}catch(err){}
try{if(!localStorage.getItem("highlights.v1"))localStorage.setItem("highlights.v1",JSON.stringify({version:"seen"}));}catch(err){}
var SEL="header,aside,[data-slot=user-message-meta],[data-slot=text-part-meta],button[data-action=prompt-model]";
function hideNow(n){try{var e=n.querySelectorAll(SEL);for(var i=0;i<e.length;i++)e[i].style.setProperty("display","none","important");}catch(err){}}
function hideAll(){try{var e=document.querySelectorAll(SEL);for(var i=0;i<e.length;i++)e[i].style.setProperty("display","none","important");}catch(err){}}
function ag(){try{var m=document.querySelector("button[data-action=prompt-model]");if(!m||!m.parentElement)return;var host=m.parentElement,cur=localStorage.getItem(AG)||"plan",bar=document.querySelector("[data-zx-ag]");if(bar&&bar.dataset.v===cur)return;if(!bar){bar=document.createElement("div");bar.setAttribute("data-zx-ag","1");host.appendChild(bar);}bar.dataset.v=cur;bar.textContent="";["plan","build"].forEach(function(a){var b=document.createElement("button");b.textContent=a==="plan"?"Plan":"Build";if(a===cur)b.className="on";b.addEventListener("click",function(){try{fetch("/api/session/ses_guest/agent",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agent:a})});}catch(err){}localStorage.setItem(AG,a);bar.dataset.v="";ag();});bar.appendChild(b);});}catch(err){}}
function guard(){var p=location.pathname;if((p==="/"||p==="/global"||p==="/global/")&&S)location.replace(S);}
function syncAgent(){var want=localStorage.getItem(AG)||"plan";try{fetch("/api/session/ses_guest",{headers:{Accept:"application/json"}}).then(function(r){return r.json();}).then(function(d){var cur=d&&d.data&&d.data.agent;if(cur&&cur!==want)return fetch("/api/session/ses_guest/agent",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agent:want})}).catch(function(){});}).catch(function(){});}catch(err){}}
var q=[],sched=false;
function flush(){sched=false;var l=q;q=[];for(var i=0;i<l.length;i++)hideNow(l[i]);ag();}
function onMut(recs){var dirty=false;for(var i=0;i<recs.length;i++){var r=recs[i];if(r.type!=="childList")continue;dirty=true;for(var j=0;j<r.addedNodes.length;j++){var a=r.addedNodes[j];if(a.nodeType===1)q.push(a);}}if(dirty&&!sched){sched=true;requestAnimationFrame(flush);}}
function run(){hideAll();ag();}
new MutationObserver(onMut).observe(document.documentElement,{childList:true,subtree:true});
document.addEventListener("DOMContentLoaded",function(){run();syncAgent();});run();guard();setInterval(guard,800);
function keyb(ev){if(!(ev.metaKey||ev.ctrlKey))return;var k=(ev.key||"").toLowerCase();if(k==="k"||k==="n"||k===","||k==="p"||(k==="r"&&ev.shiftKey)){ev.preventDefault();ev.stopImmediatePropagation();}}
window.addEventListener("keydown",keyb,true);document.addEventListener("keydown",keyb,true);
function slashG(ev){var k=ev.key;if(k!=="/"&&k!=="Enter")return;var t=ev.target;var pi=t&&t.closest?t.closest('[data-component="prompt-input"]'):null;if(!pi)return;var x=(pi.textContent||"").trim();if(k==="/"&&x===""){ev.preventDefault();ev.stopImmediatePropagation();}if(k==="Enter"&&!ev.shiftKey&&x.charAt(0)==="/"){ev.preventDefault();ev.stopImmediatePropagation();}}
window.addEventListener("keydown",slashG,true);
})();`;

let shellCache = null; // { html, at }
async function fetchUpstreamHtml(tries = 5) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(UPSTREAM + "/", { headers: { accept: "text/html" } });
      if (r.ok) return r;
      lastErr = new Error("upstream " + r.status);
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw lastErr;
}

function injectShell(html) {
  const preload = '<link rel="preload" as="font" type="font/ttf" href="/assets/Inter.ttf" crossorigin>';
  const inject = "<style>" + SHELL_CSS + "</style>" + preload + "<script>" + SHELL_CLIENT + "</scr" + "ipt>";
  if (html.includes("<head>")) return html.replace("<head>", "<head>" + inject);
  if (html.includes("</head>")) return html.replace("</head>", inject + "</head>");
  return inject + html;
}

async function serveShell(req, res) {
  const now = Date.now();
  let html;
  try {
    if (!shellCache || now - shellCache.at > 30000) {
      const r = await fetchUpstreamHtml(20);
      shellCache = { html: await r.text(), at: now };
    }
    html = injectShell(shellCache.html);
  } catch {
    return send(res, 200,
      '<!doctype html><meta charset=utf-8><p style="font:14px system-ui;padding:2rem">沙盒正在启动，请稍后刷新。</p>',
      { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  }
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(req.method === "HEAD" ? undefined : html);
}
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

// 访客后端是否在约定端口监听
function appUp() {
  return new Promise((resolve) => {
    const s = netConnect({ host: "127.0.0.1", port: APP_PORT });
    let done = false;
    const finish = (v) => { if (done) return; done = true; s.destroy(); resolve(v); };
    s.setTimeout(400);
    s.once("connect", () => finish(true));
    s.once("timeout", () => finish(false));
    s.once("error", () => finish(false));
  });
}

// 把请求整体反代到访客后端(方法/请求体/响应体都透传)
function proxyToApp(req, res, path, search) {
  const headers = { ...req.headers, host: `127.0.0.1:${APP_PORT}` };
  delete headers["connection"];
  const up = httpRequest(
    { host: "127.0.0.1", port: APP_PORT, method: req.method, path: path + (search || ""), headers },
    (ur) => {
      res.writeHead(ur.statusCode || 502, ur.headers);
      ur.pipe(res);
    },
  );
  up.on("error", () => {
    if (res.headersSent) res.end();
    else send(res, 502, "app unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  });
  req.pipe(up);
}

async function servePreview(req, res, pathname, search) {
  const isRead = req.method === "GET" || req.method === "HEAD";
  let rel = pathname.replace(/^\/preview\/?/, "");
  try {
    rel = decodeURIComponent(rel);
  } catch {
    return send(res, 400, "bad path");
  }
  if (rel.includes("\0")) return send(res, 400, "bad path");
  const target = resolve(join(WORKSPACE, rel));
  if (target !== WORKSPACE && !target.startsWith(WORKSPACE + sep)) return send(res, 403, "forbidden");

  // ① 静态文件优先:存在就直接读(不列目录)
  if (isRead) {
    let st = null;
    try { st = await stat(target); } catch {}
    if (st && st.isFile()) return serveFile(req, res, target);
    if (st && st.isDirectory()) {
      const idx = join(target, "index.html");
      let st2 = null;
      try { st2 = await stat(idx); } catch {}
      if (st2 && st2.isFile()) return serveFile(req, res, idx);
      if (pathname === "/preview" || pathname === "/preview/") {
        if (await appUp()) return proxyToApp(req, res, "/", search);
        return send(res, 200, PREVIEW_HINT, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      }
    }
  }

  // ② 其余(不存在的前端资源 / API / 写请求)→ 反代到访客后端(约定端口 8000)
  if (await appUp()) return proxyToApp(req, res, "/" + rel, search);
  return notFound(res);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname;

  // 预览(含访客后端反代)支持任意方法(GET/HEAD/POST/PUT/DELETE…),先于只读校验
  if (pathname === "/preview" || pathname.startsWith("/preview/")) return servePreview(req, res, pathname, url.search);

  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "method not allowed");
  if (pathname === "/__hub") return serveHub(req, res);
  if (pathname === "/__shell") return serveShell(req, res);
  if (pathname === "/__config") return serveSanitizedConfig(res, "/config", url.search);
  if (pathname === "/__gconfig") return serveSanitizedConfig(res, "/global/config", url.search);
  if (pathname === "/__preview-health") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  return notFound(res);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[sandbox-helper] listening on :${PORT} (workspace=${WORKSPACE}, session=${SESSION_ID})`);
});
