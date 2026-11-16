# AtomOne with the VAAS provider wired in. Build context: an AtomOne checkout
# (ATOMONE_SRC). MIN_VOTING_PERIOD lowers both governance voting-period
# floors (AtomOne's and atomone-sdk's), which a test network needs.
ARG GO_VERSION=1.26.11
FROM golang:${GO_VERSION}-alpine AS builder
RUN apk add --no-cache git make bash gcc libc-dev linux-headers
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod go mod download
COPY . .
ARG MIN_VOTING_PERIOD=60s
ARG VERSION=localnet
ARG COMMIT=unknown
RUN --mount=type=cache,id=gomod,target=/go/pkg/mod \
    --mount=type=cache,id=gobuild,target=/root/.cache/go-build \
    CGO_ENABLED=0 make install MIN_VOTING_PERIOD=${MIN_VOTING_PERIOD} VERSION=${VERSION} COMMIT=${COMMIT}

FROM alpine:3.22
RUN apk add --no-cache bash curl jq
COPY --from=builder /go/bin/atomoned /usr/local/bin/atomoned
EXPOSE 26656 26657 1317 9090 26660
ENTRYPOINT []
