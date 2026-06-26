#!/usr/bin/env python3
"""Create or update the sticky Forgejo PR CI summary comment."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

MARKER = "dotfiles-ci-summary:v1"
COMMENT_PAGE_LIMIT = 100


def load_renderer():
    renderer_path = Path(
        os.environ.get(
            "DOTFILES_CI_SUMMARY_RENDERER",
            str(Path(__file__).with_name("render-ci-summary-comment.py")),
        )
    )
    spec = importlib.util.spec_from_file_location("render_ci_summary_comment", renderer_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load renderer from {renderer_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_tea(args: list[str], *, input_text: str | None = None) -> str:
    tea_bin = os.environ.get("DOTFILES_TEA_BIN", "tea")
    proc = subprocess.run(
        [tea_bin, *args],
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise RuntimeError(f"{tea_bin} {' '.join(args)} failed: {detail}")
    return proc.stdout


def tea_api(endpoint: str, *, repo: str | None, method: str = "GET", body: dict[str, Any] | None = None) -> str:
    args = ["api"]
    if repo:
        args.extend(["--repo", repo])
    if method != "GET":
        args.extend(["--method", method])
    cleanup_path: str | None = None
    try:
        if body is not None:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as fh:
                json.dump(body, fh)
                cleanup_path = fh.name
            args.extend(["--data", f"@{cleanup_path}"])
        args.append(endpoint)
        return run_tea(args)
    finally:
        if cleanup_path:
            try:
                os.unlink(cleanup_path)
            except FileNotFoundError:
                pass


def comment_body(comment: Any) -> str:
    if not isinstance(comment, dict):
        return ""
    body = comment.get("body", comment.get("content", comment.get("text", "")))
    return body if isinstance(body, str) else ""


def comment_id(comment: Any) -> int | str | None:
    if not isinstance(comment, dict):
        return None
    value = comment.get("id")
    if value is None:
        return None
    if isinstance(value, (int, str)):
        return value
    return None


def comment_author(comment: Any) -> str:
    if not isinstance(comment, dict):
        return ""
    for key in ("user", "poster", "author"):
        value = comment.get(key)
        if not isinstance(value, dict):
            continue
        for name_key in ("login", "login_name", "username", "name"):
            name = value.get(name_key)
            if isinstance(name, str) and name:
                return name
    return ""


def marker_sha(body: str) -> str:
    match = re.search(r"dotfiles-ci-summary:v1 sha=([A-Za-z0-9._/-]+)", body)
    return match.group(1) if match else ""


def load_comments(text: str) -> list[Any]:
    if not text.strip():
        return []
    data = json.loads(text)
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("comments", "data", "items"):
            value = data.get(key)
            if isinstance(value, list):
                return value
    raise ValueError("Forgejo comments response was not a JSON list")


def fetch_comments(pr: str, *, repo: str | None) -> list[Any]:
    comments: list[Any] = []
    page = 1
    while True:
        text = tea_api(
            f"/repos/{{owner}}/{{repo}}/issues/{pr}/comments?limit={COMMENT_PAGE_LIMIT}&page={page}",
            repo=repo,
        )
        page_comments = load_comments(text)
        comments.extend(page_comments)
        if len(page_comments) < COMMENT_PAGE_LIMIT:
            return comments
        page += 1


def parse_json_object(text: str, description: str) -> dict[str, Any]:
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError(f"{description} response was not a JSON object")
    return data


def pr_head_sha(pr: dict[str, Any]) -> str:
    head = pr.get("head")
    if not isinstance(head, dict):
        return ""
    candidates = [
        head.get("sha"),
        (head.get("commit") or {}).get("sha") if isinstance(head.get("commit"), dict) else None,
        (head.get("commit") or {}).get("id") if isinstance(head.get("commit"), dict) else None,
    ]
    for candidate in candidates:
        if isinstance(candidate, str) and candidate:
            return candidate
    return ""


def current_login(user: dict[str, Any]) -> str:
    for key in ("login", "login_name", "username", "name"):
        value = user.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def choose_sticky_comment(comments: list[Any], head: str, author: str) -> Any | None:
    sticky = [comment for comment in comments if MARKER in comment_body(comment)]
    if author:
        sticky = [comment for comment in sticky if comment_author(comment) == author]
    if not sticky:
        return None
    current = [comment for comment in sticky if marker_sha(comment_body(comment)) == head]
    return (current or sticky)[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pr", help="Forgejo PR number")
    parser.add_argument("summary", help="check-summary.json path")
    parser.add_argument("--repo", help="Forgejo repository slug for tea, for example owner/name")
    parser.add_argument(
        "--author",
        help="reporter comment author login; defaults to the authenticated tea user",
    )
    parser.add_argument(
        "--allow-stale",
        action="store_true",
        help="post even when the summary head does not match the PR head",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="render and print the comment without calling tea",
    )
    args = parser.parse_args()

    try:
        with open(args.summary, "r", encoding="utf-8") as fh:
            summary = json.load(fh)
        if not isinstance(summary, dict):
            raise ValueError("summary root must be an object")
        if summary.get("schema") != MARKER:
            raise ValueError(f"summary schema must be {MARKER}")
        head = str(summary.get("head") or "")
        if not head:
            raise ValueError("summary head is required")

        renderer = load_renderer()
        rendered = renderer.render(summary)
        if args.dry_run:
            sys.stdout.write(rendered)
            return 0

        pr_text = tea_api(
            f"/repos/{{owner}}/{{repo}}/pulls/{args.pr}",
            repo=args.repo,
        )
        pr = parse_json_object(pr_text, "Forgejo PR")
        current_head = pr_head_sha(pr)
        if not current_head and not args.allow_stale:
            raise ValueError("could not determine current PR head; refusing to post CI comment")
        if current_head and current_head != head and not args.allow_stale:
            raise ValueError(
                f"summary head {head} does not match current PR head {current_head}; refusing stale CI comment"
            )

        author = args.author
        if author is None:
            user_text = tea_api("/user", repo=args.repo)
            author = current_login(parse_json_object(user_text, "Forgejo user"))
            if not author:
                raise ValueError("could not determine authenticated tea user for sticky comment ownership")

        comments = fetch_comments(args.pr, repo=args.repo)
        existing = choose_sticky_comment(comments, head, author)
        if existing is None:
            tea_api(
                f"/repos/{{owner}}/{{repo}}/issues/{args.pr}/comments",
                repo=args.repo,
                method="POST",
                body={"body": rendered},
            )
            print(f"created {MARKER} comment for PR #{args.pr} at {head}")
            return 0

        existing_id = comment_id(existing)
        if existing_id is None:
            raise ValueError("existing sticky comment has no id")
        tea_api(
            f"/repos/{{owner}}/{{repo}}/issues/comments/{existing_id}",
            repo=args.repo,
            method="PATCH",
            body={"body": rendered},
        )
        print(f"updated {MARKER} comment {existing_id} for PR #{args.pr} at {head}")
        return 0
    except (OSError, json.JSONDecodeError, ValueError, RuntimeError) as exc:
        print(f"post-ci-summary-comment: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
