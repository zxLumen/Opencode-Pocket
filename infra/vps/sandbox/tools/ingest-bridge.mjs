// 通用弹幕桥接:把「一行一条弹幕」的输入转发到沙盒 /__lb/ingest。
//
// 用途:当你用一个本机抓取器(任意语言/库)拿到抖音弹幕时,直接调用本文件的 post();
//      或把「用户<TAB>文本」逐行喂给 stdin。
//
// 用法:
//   INGEST_TOKEN=xxx node ingest-bridge.mjs < danmaku.txt
//   # 或在自己脚本里: import { post } from "./ingest-bridge.mjs"; post("666","用户A")
const INGEST_URL = process.env.INGEST_URL || "https://code-sandbox.zxlumen.cn/__lb/ingest";
const TOKEN = process.env.INGEST_TOKEN || "";
const PLATFORM = process.env.INGEST_PLATFORM || "douyin";

export async function post(text, user) {
  text = String(text || "").trim();
  if (!text || !TOKEN) return false;
  const r = await fetch(INGEST_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-ingest-token": TOKEN },
    body: JSON.stringify({ platform: PLATFORM, user: String(user || ""), text }),
  });
  return r.ok;
}

export async function postBatch(list) {
  if (!TOKEN || !Array.isArray(list) || !list.length) return false;
  const r = await fetch(INGEST_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-ingest-token": TOKEN },
    body: JSON.stringify({ messages: list.map((m) => ({ platform: PLATFORM, user: m.user || "", text: m.text || "" })) }),
  });
  return r.ok;
}

// 作为 CLI:从 stdin 读「每行一条弹幕」(可 "用户<TAB>文本")。
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/").split("/").pop())) {
  if (!TOKEN) { console.error("[ingest-bridge] 请设置 INGEST_TOKEN"); process.exit(1); }
  console.error("[ingest-bridge] 读 stdin →", INGEST_URL, "(PLATFORM=" + PLATFORM + ")");
  process.stdin.setEncoding("utf8");
  let buf = "";
  process.stdin.on("data", (c) => {
    buf += c;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      const parts = line.includes("\t") ? line.split("\t") : ["", line];
      post(parts[1], parts[0]).catch(() => {});
    }
  });
}
