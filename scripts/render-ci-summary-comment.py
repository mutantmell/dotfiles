#!/usr/bin/env python3
"""Render a bounded Forgejo PR comment from check-summary.json."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

MAX_FAILURES = 8
MAX_LOG_LINES = 80
MAX_LOG_BYTES = 12000
MAX_FIELD_CHARS = 300
MAX_COMMAND_CHARS = 1200
SECRET_PATTERNS = [
    re.compile(r"((?:TOKEN|SECRET|PASSWORD|PASS|KEY)[A-Za-z0-9_]*=)[^\s]+", re.IGNORECASE),
    re.compile(r"([A-Za-z_][A-Za-z0-9_]*_(?:TOKEN|SECRET|PASSWORD|PASS|KEY)[A-Za-z0-9_]*=)[^\s]+", re.IGNORECASE),
    re.compile(r"(Authorization:\s*(?:Bearer|token)\s+)[^\s]+", re.IGNORECASE),
    re.compile(r"(https?://[^\s:@]+:)[^\s:@]+(@)", re.IGNORECASE),
]


def scalar(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value)
    return json.dumps(value, sort_keys=True)


def bounded(value: Any, limit: int = MAX_FIELD_CHARS) -> str:
    text = redact(scalar(value).replace("\r\n", "\n").replace("\r", "\n"))
    if len(text) <= limit:
        return text
    return text[:limit] + "... truncated"


def inline_code(value: Any) -> str:
    text = bounded(value).replace("\n", " ")
    return "`" + text.replace("`", "'") + "`"


def markdown_text(value: Any) -> str:
    text = bounded(value)
    return re.sub(r"([\\`*_{}\[\]()#+.!|<>-])", r"\\\1", text)


def redact(text: str) -> str:
    for pattern in SECRET_PATTERNS:
        if pattern.groups == 2:
            text = pattern.sub(r"\1[REDACTED]\2", text)
        else:
            text = pattern.sub(r"\1[REDACTED]", text)
    return text


def log_block(value: Any) -> str:
    text = bounded(value, MAX_LOG_BYTES)
    raw = text.encode("utf-8", "replace")[:MAX_LOG_BYTES]
    text = raw.decode("utf-8", "replace")
    lines = text.splitlines()
    truncated = len(lines) > MAX_LOG_LINES or len(raw) == MAX_LOG_BYTES
    lines = lines[-MAX_LOG_LINES:]
    if not lines:
        return "    <no log tail captured>"
    rendered = "\n".join(f"    {line}" for line in lines)
    if truncated:
        rendered = "    ... truncated ...\n" + rendered
    return rendered


def command_block(value: Any) -> str:
    text = bounded(value, MAX_COMMAND_CHARS)
    lines = text.splitlines() or [""]
    return "\n".join(f"    {line}" for line in lines)


def render(summary: dict[str, Any]) -> str:
    head = bounded(summary.get("head"))
    marker_head = re.sub(r"[^A-Za-z0-9._/-]", "_", head)
    status = bounded(summary.get("status") or "unknown")
    workflow = bounded(summary.get("workflow") or "unknown")
    step = bounded(summary.get("step") or "unknown")
    pipeline_url = bounded(summary.get("pipeline_url"))
    failed = summary.get("failed_checks")
    if not isinstance(failed, list):
        failed = []

    marker = f"<!-- dotfiles-ci-summary:v1 sha={marker_head} -->"
    lines = [
        marker,
        f"### CI summary: {markdown_text(status)}",
        "",
        f"- Head: {inline_code(head)}",
        f"- Workflow: {inline_code(workflow)} / {inline_code(step)}",
    ]
    if pipeline_url:
        lines.append(f"- Woodpecker run: {markdown_text(pipeline_url)}")
    lines.append("")

    if status == "passed" and not failed:
        lines.append("All reported checks passed.")
        return "\n".join(lines).rstrip() + "\n"

    if not failed:
        lines.append("No failed check details were captured.")
        return "\n".join(lines).rstrip() + "\n"

    lines.append("Failed checks:")
    shown = failed[:MAX_FAILURES]
    for check in shown:
        if not isinstance(check, dict):
            continue
        name = check.get("name", "unknown")
        reproduce = check.get("reproduce", "")
        log_url = bounded(check.get("log_url"))
        lines.extend(
            [
                "",
                f"#### {markdown_text(name)}",
                "",
                "Reproduce:",
                "",
                command_block(reproduce),
            ]
        )
        if log_url:
            lines.extend(["", f"Full log: {markdown_text(log_url)}"])
        lines.extend(["", "Log tail:", "", log_block(check.get("log_tail", ""))])

    if len(failed) > len(shown):
        lines.extend(["", f"_Omitted {len(failed) - len(shown)} additional failed checks._"])

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", nargs="?", help="check-summary.json path; reads stdin when omitted")
    args = parser.parse_args()

    try:
        if args.summary:
            with open(args.summary, "r", encoding="utf-8") as fh:
                summary = json.load(fh)
        else:
            summary = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"render-ci-summary-comment: {exc}", file=sys.stderr)
        return 2

    if not isinstance(summary, dict):
        print("render-ci-summary-comment: summary root must be an object", file=sys.stderr)
        return 2

    sys.stdout.write(render(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
