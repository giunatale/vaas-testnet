# The VAAS reference consumer. Build context: a VAAS checkout (VAAS_SRC).
# Addresses take the prefix in VAAS_BECH32_PREFIX at run time.
ARG GO_VERSION=1.26.11
FROM golang:${GO_VERSION}-alpine AS builder
RUN apk add --no-cache git make bash gcc libc-dev linux-headers
WORKDIR /src
COPY go.mod go.sum ./
COPY app/go.mod app/go.sum ./app/
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod cd app && go mod download
COPY . .
ARG VERSION=localnet
ARG COMMIT=unknown
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build \
    cd app && CGO_ENABLED=0 go build -mod=readonly \
      -ldflags "-X github.com/cosmos/cosmos-sdk/version.Name=vaas -X github.com/cosmos/cosmos-sdk/version.AppName=consumer -X github.com/cosmos/cosmos-sdk/version.Version=${VERSION} -X github.com/cosmos/cosmos-sdk/version.Commit=${COMMIT}" \
      -o /out/consumer ./cmd/consumer

FROM alpine:3.22
RUN apk add --no-cache bash curl jq
COPY --from=builder /out/consumer /usr/local/bin/consumer
EXPOSE 26656 26657 1317 9090 26660
ENTRYPOINT []
