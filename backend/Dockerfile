# F-M1-03 backend. 빌드와 런타임 모두 Debian 13(trixie) 계열 glibc.
# F-M2-03: wasmtime-go(cgo)라 CGO_ENABLED=1, golang:*-trixie 빌드 이미지에 gcc 가 있다. 런타임은 glibc 그대로(alpine/distroless-static 금지).
# wasmtime-go v50.0.0 태그는 build/linux-{aarch64,x86_64}/libwasmtime.a 를 포함하므로 별도 다운로드가 없다.
# runtime 이미지는 날짜 태그로 고정한다 (이동 태그 금지).
FROM golang:1.27.3-trixie AS build
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
	go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	CGO_ENABLED=1 go build -trimpath -o /out/api ./cmd/api

FROM debian:trixie-20261020-slim
COPY --from=build /out/api /usr/local/bin/api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/api"]
