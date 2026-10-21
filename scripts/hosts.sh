#!/usr/bin/env bash
# /etc/hosts 에 BEGIN/END 마커 블록을 쓴다. 재실행해도 블록은 1개 (INF-04).
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
BEGIN="# BEGIN lgtm"
END="# END lgtm"
LINE="127.0.0.1 lgtm.local grafana.lgtm.local ipfs.lgtm.local"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 기존 블록 제거 후 새 블록을 끝에 붙인다
awk -v b="$BEGIN" -v e="$END" '
	$0 == b { skip = 1; next }
	$0 == e { skip = 0; next }
	!skip
' "$HOSTS_FILE" >"$tmp"
printf '%s\n%s\n%s\n' "$BEGIN" "$LINE" "$END" >>"$tmp"

if cmp -s "$tmp" "$HOSTS_FILE"; then
	echo "[skip] $HOSTS_FILE (lgtm 블록 이미 최신)"
	exit 0
fi

# 같은 파일시스템이 아닌 bind mount 일 수 있으니 rename 대신 내용 덮어쓰기
if [ -w "$HOSTS_FILE" ]; then cat "$tmp" >"$HOSTS_FILE"; else sudo tee "$HOSTS_FILE" <"$tmp" >/dev/null; fi
echo "$HOSTS_FILE 갱신: $LINE"
