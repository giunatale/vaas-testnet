# gnoshard: the VAAS reference consumer with ignite/gnovm. Build context: a
# gnoshard checkout (GNOSHARD_SRC). The Gno standard library ships under
# GNOROOT: gnovm/stdlibs, which x/gnovm loads at InitGenesis, and
# gnovm/tests/stdlibs, which the VM reads when it type-checks the library's
# test files.
ARG GO_VERSION=1.26.11
FROM golang:${GO_VERSION}-alpine AS builder
RUN apk add --no-cache git make bash gcc libc-dev linux-headers
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod go mod download
COPY . .
ARG VERSION=localnet
ARG COMMIT=unknown
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -mod=readonly \
      -ldflags "-X github.com/cosmos/cosmos-sdk/version.Name=gnoshard -X github.com/cosmos/cosmos-sdk/version.AppName=gnoshardd -X github.com/cosmos/cosmos-sdk/version.Version=${VERSION} -X github.com/cosmos/cosmos-sdk/version.Commit=${COMMIT}" \
      -o /out/gnoshardd ./cmd/gnoshardd
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    gno="$(go list -m -f '{{.Dir}}' github.com/gnolang/gno)" && mkdir -p /out/gnoroot/gnovm/tests && \
    cp -r "$gno/gnovm/stdlibs" /out/gnoroot/gnovm/stdlibs && \
    cp -r "$gno/gnovm/tests/stdlibs" /out/gnoroot/gnovm/tests/stdlibs

FROM alpine:3.22
RUN apk add --no-cache bash curl jq
COPY --from=builder /out/gnoshardd /usr/local/bin/gnoshardd
COPY --from=builder /out/gnoroot /usr/local/share/gno
ENV GNOROOT=/usr/local/share/gno
EXPOSE 26656 26657 1317 9090 26660
ENTRYPOINT []
