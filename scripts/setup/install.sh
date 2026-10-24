#!/usr/bin/env bash
# docker, kubectl, helm, k3d 설치 (idempotent, amd64/arm64 자동 감지).
# 버전은 Makefile 상단 변수에서 export 된다. 이미 같은 버전이면 "[skip] <tool> <ver>"만 출력한다.
set -euo pipefail

DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
BIN_DIR=/usr/local/bin

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "Linux(Debian VM)에서만 지원합니다 (현재: $(uname -s))"

: "${K3D_VERSION:?}" "${KUBECTL_VERSION:?}" "${HELM_VERSION:?}" "${DOCKER_VERSION_STR:?}"

case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "지원하지 않는 아키텍처: $(uname -m) (amd64/arm64만 지원)" ;;
esac

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TARGET_USER="${SUDO_USER:-$(id -un)}"

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

apt_install() {
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ensure_dl_tools() {
	if command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 \
		&& [ -f /etc/ssl/certs/ca-certificates.crt ]; then
		return
	fi
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
	apt_install ca-certificates curl coreutils tar
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

install_bin() { $SUDO install -m 0755 "$1" "$BIN_DIR/$2"; }

# ---------- docker ----------
user_in_docker_group() {
	[ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ] && return 0
	getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$TARGET_USER"
}

docker_ok() {
	[ "$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)" = "$DOCKER_VERSION_STR" ] \
		&& [ "$(dpkg-query -W -f='${Version}' docker-ce-cli 2>/dev/null || true)" = "$DOCKER_VERSION_STR" ] \
		&& systemctl is-active --quiet docker \
		&& user_in_docker_group
}

install_docker() {
	if docker_ok; then
		echo "[skip] docker $DOCKER_VERSION_STR"
		return
	fi
	echo "[install] docker $DOCKER_VERSION_STR"
	# shellcheck disable=SC1091
	. /etc/os-release
	[ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "trixie" ] \
		|| echo "WARN: Debian 13(trixie)이 아님: ${PRETTY_NAME:-unknown}" >&2

	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
	apt_install ca-certificates curl gnupg
	TMP="$(mktemp -d)"
	fetch https://download.docker.com/linux/debian/gpg "$TMP/docker.asc"
	got="$(gpg --show-keys --with-colons "$TMP/docker.asc" | awk -F: '$1=="fpr"{print $10; exit}')"
	[ "$got" = "$DOCKER_GPG_FPR" ] || die "docker GPG 핑거프린트 불일치: $got"
	$SUDO install -m 0755 -d /etc/apt/keyrings
	$SUDO install -m 0644 "$TMP/docker.asc" /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
		| $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update

	# docker-compose-plugin 은 설치하지 않는다
	$SUDO apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1 || true
	apt_install --allow-downgrades "docker-ce=$DOCKER_VERSION_STR" "docker-ce-cli=$DOCKER_VERSION_STR" \
		containerd.io docker-buildx-plugin
	$SUDO apt-mark hold docker-ce docker-ce-cli >/dev/null
	$SUDO systemctl enable --now docker

	if ! user_in_docker_group; then
		$SUDO usermod -aG docker "$TARGET_USER"
		echo "[info] $TARGET_USER 를 docker 그룹에 추가함 (이 make 안에서는 scripts/lib/with-docker.sh 가 sg 로 처리)"
	fi
	"$(dirname "${BASH_SOURCE[0]}")/../lib/with-docker.sh" docker info >/dev/null \
		|| die "docker 그룹 권한으로 docker info 실패"
	cleanup; TMP=""
}

# ---------- kubectl ----------
install_kubectl() {
	local cur
	cur="$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version: //p' || true)"
	if [ "$cur" = "$KUBECTL_VERSION" ]; then echo "[skip] kubectl $KUBECTL_VERSION"; return; fi
	echo "[install] kubectl $KUBECTL_VERSION"
	ensure_dl_tools
	TMP="$(mktemp -d)"
	local base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH"
	fetch "$base/kubectl" "$TMP/kubectl"
	fetch "$base/kubectl.sha256" "$TMP/kubectl.sha256"
	(cd "$TMP" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - >/dev/null) \
		|| die "kubectl checksum 불일치"
	install_bin "$TMP/kubectl" kubectl
	cleanup; TMP=""
}

# ---------- helm ----------
install_helm() {
	local cur
	cur="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
	if [ "$cur" = "$HELM_VERSION" ]; then echo "[skip] helm $HELM_VERSION"; return; fi
	echo "[install] helm $HELM_VERSION"
	ensure_dl_tools
	TMP="$(mktemp -d)"
	local f="helm-$HELM_VERSION-linux-$ARCH.tar.gz"
	fetch "https://get.helm.sh/$f" "$TMP/$f"
	fetch "https://get.helm.sh/$f.sha256sum" "$TMP/$f.sha256sum"
	(cd "$TMP" && sha256sum -c "$f.sha256sum" >/dev/null) || die "helm checksum 불일치"
	tar -xzf "$TMP/$f" -C "$TMP"
	install_bin "$TMP/linux-$ARCH/helm" helm
	cleanup; TMP=""
}

# ---------- k3d ----------
install_k3d() {
	local cur
	cur="$(k3d version 2>/dev/null | sed -n '1s/^k3d version //p' || true)"
	if [ "$cur" = "$K3D_VERSION" ]; then echo "[skip] k3d $K3D_VERSION"; return; fi
	echo "[install] k3d $K3D_VERSION"
	ensure_dl_tools
	TMP="$(mktemp -d)"
	local base="https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION"
	fetch "$base/k3d-linux-$ARCH" "$TMP/k3d-linux-$ARCH"
	fetch "$base/checksums.txt" "$TMP/checksums.txt"
	# checksums.txt 항목은 "<sha256>  _dist/k3d-linux-<arch>" 형식
	local sum
	sum="$(awk -v n="k3d-linux-$ARCH" '{p=$2; sub(".*/","",p); if (p==n) {print $1; exit}}' "$TMP/checksums.txt")"
	[ -n "$sum" ] || die "checksums.txt 에 k3d-linux-$ARCH 항목 없음"
	(cd "$TMP" && echo "$sum  k3d-linux-$ARCH" | sha256sum -c - >/dev/null) || die "k3d checksum 불일치"
	install_bin "$TMP/k3d-linux-$ARCH" k3d
	cleanup; TMP=""
}

install_docker
install_kubectl
install_helm
install_k3d
