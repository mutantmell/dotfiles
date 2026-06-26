{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.runCommand "ci-summary-render-test" {
  nativeBuildInputs = [pkgs.python3];
} ''
  cat > summary.json <<'JSON'
  {
    "schema": "dotfiles-ci-summary:v1",
    "head": "abc123",
    "status": "failed",
    "repository": "mutantmell/dotfiles",
    "pipeline_number": "42",
    "pipeline_url": "https://woodpecker.internal/repos/mutantmell/dotfiles/pipeline/42",
    "workflow": "full-checks",
    "step": "full-checks",
    "failed_checks": [
      {
        "name": "network-registry *boom*",
        "reproduce": "./scripts/run-checks.sh network-registry\nTOKEN=commandsecret\n# not a command heading",
        "log_url": "https://user:logsecret@woodpecker.internal/repos/mutantmell/dotfiles/log",
        "log_tail": "TOKEN=supersecret\n```markdown\n# not a heading\n"
      }
    ]
  }
  JSON

  python3 ${../../scripts/render-ci-summary-comment.py} summary.json > comment.md

  grep -F '<!-- dotfiles-ci-summary:v1 sha=abc123 -->' comment.md
  grep -F 'CI summary: failed' comment.md
  grep -F '#### network\-registry \*boom\*' comment.md
  grep -F '    ./scripts/run-checks.sh network-registry' comment.md
  grep -F '    TOKEN=[REDACTED]' comment.md
  grep -F '    # not a command heading' comment.md
  grep -F 'Full log: https://user:\[REDACTED\]@woodpecker\.internal/repos/mutantmell/dotfiles/log' comment.md
  grep -F '    TOKEN=[REDACTED]' comment.md
  ! grep -F 'supersecret' comment.md
  ! grep -F 'commandsecret' comment.md
  ! grep -F 'logsecret' comment.md
  grep -F '    ```markdown' comment.md
  grep -F '    # not a heading' comment.md

  touch $out
''
