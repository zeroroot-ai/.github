ARG GO_VERSION=1.26.8
ARG GOTOOLCHAIN=local
FROM golang:${GO_VERSION}-bookworm AS build
RUN go build ./...
