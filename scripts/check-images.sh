#!/usr/bin/env bash
# images.txt 와 k8s manifest / Dockerfile / Makefile 의 불일치를 검사한다 (불일치 0 이어야 exit 0). Mac/Linux 공용(grep/awk).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

role_images() { awk -v r="$1" '!/^[[:space:]]*(#|$)/ && $1 == r {print $2}' images.txt | sort -u; }

# compare <이름> <list에서 나온 값> <실제로 쓰인 값>
compare() {
	local only_list only_used
	only_list="$(comm -23 <(printf '%s\n' "$2") <(printf '%s\n' "$3"))"
	only_used="$(comm -13 <(printf '%s\n' "$2") <(printf '%s\n' "$3"))"
	[ -z "$only_used" ] || fail "$1: 사용 중인데 images.txt 에 없음: $(echo $only_used)"
	[ -z "$only_list" ] || fail "$1: images.txt 에만 있고 사용처 없음: $(echo $only_list)"
}

# workload: k8s/**/*.yaml 의 image: (치환 자리표시자 __X__ 제외)
used_workload="$(grep -rhE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]' k8s | awk '{print $NF}' | grep -v '^__' | sort -u)"
compare workload "$(role_images workload)" "$used_workload"

# build: Dockerfile FROM (같은 파일 안의 AS 별칭 참조는 제외)
used_build="$(for f in backend/Dockerfile* frontend/Dockerfile; do
	awk 'toupper($1)=="FROM" {print $2; for (i=3;i<=NF;i++) if (toupper($i)=="AS") alias[$(i+1)]=1} END{}' "$f" |
		while read -r img; do
			awk -v a="$img" 'toupper($1)=="FROM" {for (i=3;i<=NF;i++) if (toupper($i)=="AS" && $(i+1)==a) f=1} END{exit !f}' "$f" || echo "$img"
		done
done | sort -u)"
compare build "$(role_images build)" "$used_build"

# infra: Makefile K3S_IMAGE 가 목록에 있어야 한다 (k3d helper 는 k3d 버전과 짝이라 존재 여부만 본다)
k3s="$(sed -n 's/^K3S_IMAGE[[:space:]]*:=[[:space:]]*//p' Makefile | head -1)"
[ -n "$k3s" ] || fail "Makefile 에서 K3S_IMAGE 를 못 찾음"
role_images infra | grep -qxF "$k3s" || fail "infra: Makefile K3S_IMAGE($k3s) 가 images.txt 에 없음"
k3d_v="$(sed -n 's/^K3D_VERSION[[:space:]]*:=[[:space:]]*v//p' Makefile | head -1)"
for h in k3d-proxy k3d-tools; do
	role_images infra | grep -qxF "ghcr.io/k3d-io/$h:$k3d_v" || fail "infra: ghcr.io/k3d-io/$h:$k3d_v (K3D_VERSION 과 짝) 가 images.txt 에 없음"
done

# 태그 고정: 태그 없음 / :latest 금지
bad_tag="$(grep -vE '^[[:space:]]*(#|$)' images.txt | awk '$2 ~ /:latest$/ || $2 !~ /:/ {print $2}')"
[ -z "$bad_tag" ] || fail "태그 없음/:latest: $(echo $bad_tag)"

# imagePullPolicy: manifest 의 모든 image: 줄 바로 다음 줄이 IfNotPresent
for f in $(find k8s -name '*.yaml' | sort); do
	awk -v f="$f" '
		prev_image && $0 !~ /imagePullPolicy:[[:space:]]*IfNotPresent/ { printf "FAIL: %s:%d image 다음 줄이 imagePullPolicy: IfNotPresent 가 아님\n", f, NR-1 > "/dev/stderr"; bad=1 }
		{ prev_image = ($0 ~ /^[[:space:]]*-?[[:space:]]*image:[[:space:]]/) }
		END { exit bad }' "$f" || fails=$((fails + 1))
done

[ "$fails" -eq 0 ] || exit 1
echo "check-images: 불일치 0"
