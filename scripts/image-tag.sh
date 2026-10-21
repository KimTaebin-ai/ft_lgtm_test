#!/usr/bin/env bash
# 소스 content hash 로 이미지 태그를 만든다 (VM 에는 .git 이 없고, 같은 소스는 같은 태그여야 idempotent).
# usage: image-tag.sh <dir>   → 12자 hex 출력. 파일 경로 + 내용이 입력이며 mtime 은 무관.
set -euo pipefail
dir="${1:?usage: $0 <dir>}"
cd "$(dirname "${BASH_SOURCE[0]}")/../$dir"
find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12
