# F-M1-03 backend. 빌드와 런타임 모두 Debian 13(trixie) 계열 glibc.
# F-M2-03에서 wasmtime-go(cgo, glibc 링크)로 바뀌어도 base 교체가 필요 없도록 alpine/distroless-static을 피한다.
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
	CGO_ENABLED=0 go build -trimpath -o /out/api ./cmd/api

FROM debian:trixie-20261020-slim
COPY --from=build /out/api /usr/local/bin/api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/api"]
