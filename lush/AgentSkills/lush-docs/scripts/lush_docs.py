#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def default_connection_paths():
    home = Path.home()
    return [
        home / "Library/Containers/party.chee.patchwork.lush/Data/Library"
        / "Application Support/Lush/agent.json",
        home / "Library/Application Support/Lush/agent.json",
    ]


def connection():
    override = os.environ.get("LUSH_AGENT_CONNECTION")
    candidates = [Path(override).expanduser()] if override else default_connection_paths()
    for path in candidates:
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            continue
    raise SystemExit("Lush is not running or its agent API is unavailable.")


def request(method, path, body=None):
    config = connection()
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        config["url"] + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + config["token"],
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("error", str(error))
        except Exception:
            message = str(error)
        raise SystemExit(message)
    except urllib.error.URLError:
        raise SystemExit("Lush is not running or its agent API is unavailable.")


def query(path, **values):
    filtered = {key: value for key, value in values.items() if value is not None}
    return path + "?" + urllib.parse.urlencode(filtered)


def content(args):
    if getattr(args, "file", None):
        return Path(args.file).read_text()
    return getattr(args, "text", None)


def print_json(value):
    print(json.dumps(value, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(prog="lush-docs")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("list")
    search = commands.add_parser("search")
    search.add_argument("query")
    folder = commands.add_parser("folder")
    folder.add_argument("url")
    read = commands.add_parser("read")
    read.add_argument("url")
    create = commands.add_parser("create")
    create.add_argument("--folder")
    create.add_argument("--title", default="")
    create_content = create.add_mutually_exclusive_group()
    create_content.add_argument("--text")
    create_content.add_argument("--file")
    write = commands.add_parser("write")
    write.add_argument("url")
    write.add_argument("--title")
    write.add_argument("--heads")
    write_content = write.add_mutually_exclusive_group(required=True)
    write_content.add_argument("--text")
    write_content.add_argument("--file")
    open_doc = commands.add_parser("open")
    open_doc.add_argument("url")
    args = parser.parse_args()

    if args.command == "status":
        result = request("GET", "/v1/status")
    elif args.command == "list":
        result = request("GET", "/v1/notes")
    elif args.command == "search":
        result = request("GET", query("/v1/notes", query=args.query))
    elif args.command == "folder":
        result = request("GET", query("/v1/folder", url=args.url))
    elif args.command == "read":
        result = request("GET", query("/v1/note", url=args.url))
    elif args.command == "create":
        body = {"title": args.title}
        if args.folder:
            body["folder_url"] = args.folder
        if content(args) is not None:
            body["text"] = content(args)
        result = request("POST", "/v1/notes", body)
    elif args.command == "write":
        body = {"text": content(args)}
        if args.title is not None:
            body["title"] = args.title
        if args.heads:
            body["heads"] = [head for head in args.heads.split(",") if head]
        result = request("PUT", query("/v1/note", url=args.url), body)
    else:
        components = urllib.parse.urlencode({"doc": args.url})
        subprocess.run(["open", "lush://show?" + components], check=True)
        result = {"opened": args.url}
    print_json(result)


if __name__ == "__main__":
    main()
