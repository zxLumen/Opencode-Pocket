#!/usr/bin/env python3
"""把新版本号/日期/大小写回 docs/apps.json，供 SideStore 识别「有更新」。"""
import json
import sys


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} VERSION DATE SIZE_BYTES")
    ver, date, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
    path = "docs/apps.json"
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    app = data["apps"][0]
    app["version"] = ver
    app["versionDate"] = date
    app["size"] = size
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"bumped: {ver} {date} {size}")


if __name__ == "__main__":
    main()