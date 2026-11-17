# The VAAS reference consumer, and consumer-forge: the same app with one
# configurable lie about who signed each block (tests/e2e/forge in VAAS), run
# by the forge consumer. Build context: a VAAS checkout (VAAS_SRC). Addresses
# take the prefix in VAAS_BECH32_PREFIX at run time.
ARG GO_VERSION=1.26.11
FROM golang:${GO_VERSION}-alpine AS builder
RUN apk add --no-cache git make bash gcc libc-dev linux-headers
WORKDIR /src
COPY go.mod go.sum ./
COPY app/go.mod app/go.sum ./app/
COPY tests/e2e/forge/go.mod tests/e2e/forge/go.sum ./tests/e2e/forge/
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    (cd app && go mod download) && (cd tests/e2e/forge && go mod download)
COPY . .
ARG VERSION=localnet
ARG COMMIT=unknown
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build \
    cd app && CGO_ENABLED=0 go build -mod=readonly \
      -ldflags "-X github.com/cosmos/cosmos-sdk/version.Name=vaas -X github.com/cosmos/cosmos-sdk/version.AppName=consumer -X github.com/cosmos/cosmos-sdk/version.Version=${VERSION} -X github.com/cosmos/cosmos-sdk/version.Commit=${COMMIT}" \
      -o /out/consumer ./cmd/consumer
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build \
    cd tests/e2e/forge && CGO_ENABLED=0 go build -mod=readonly -o /out/consumer-forge .

FROM alpine:3.22
RUN apk add --no-cache bash curl jq
COPY --from=builder /out/consumer /out/consumer-forge /usr/local/bin/
EXPOSE 26656 26657 1317 9090 26660
ENTRYPOINT []
