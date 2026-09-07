ARG GOTOOLCHAIN=local
FROM ghcr.io/zeroroot-ai/mirror/golang:1.26.8-alpine AS builder
ENV GOTOOLCHAIN=${GOTOOLCHAIN}
RUN go build ./...
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out /app
