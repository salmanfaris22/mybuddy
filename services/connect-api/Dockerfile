# syntax=docker/dockerfile:1
# MyBuddy Connect API — static Go binary on a distroless, non-root base.
#   docker build -t mybuddy/connect-api services/connect-api
# For reproducible production builds, pin both base images by digest (docker buildx imagetools inspect).
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/connect-api ./cmd/connect-api

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/connect-api /connect-api
USER nonroot:nonroot
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/connect-api", "healthcheck"]
ENTRYPOINT ["/connect-api"]
