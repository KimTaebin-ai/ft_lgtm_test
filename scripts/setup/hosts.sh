#!/usr/bin/env bash
# /etc/hosts 에 BEGIN/END 마커 블록을 쓴다. 재실행해도 블록은 1개 (INF-04).
# --remove: 블록만 지운다 (make fclean). 블록이 없으면 [skip].
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
BEGIN="# BEGIN lgtm"
END="# END lgtm"
LINE="127.0.0.1 lgtm.local grafana.lgtm.local ipfs.lgtm.local"

mode=add
case "${1:-}" in
	"") ;;
	--remove) mode=remove ;;
	*) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 기존 블록 제거 후 (add 이면) 새 블록을 끝에 붙인다
awk -v b="$BEGIN" -v e="$END" '
	$0 == b { skip = 1; next }
	$0 == e { skip = 0; next }
	!skip
' "$HOSTS_FILE" >"$tmp"
[ "$mode" = remove ] || printf '%s\n%s\n%s\n' "$BEGIN" "$LINE" "$END" >>"$tmp"

if cmp -s "$tmp" "$HOSTS_FILE"; then
	if [ "$mode" = remove ]; then echo "[skip] $HOSTS_FILE (lgtm 블록 없음)"; else echo "[skip] $HOSTS_FILE (lgtm 블록 이미 최신)"; fi
	exit 0
fi

# 같은 파일시스템이 아닌 bind mount 일 수 있으니 rename 대신 내용 덮어쓰기
if [ -w "$HOSTS_FILE" ]; then cat "$tmp" >"$HOSTS_FILE"; else sudo tee "$HOSTS_FILE" <"$tmp" >/dev/null; fi
if [ "$mode" = remove ]; then echo "$HOSTS_FILE 에서 lgtm 블록 제거"; else echo "$HOSTS_FILE 갱신: $LINE"; fi
