# Multi-stage build: pure Go, no CGO dependencies, so the final image can
# be a minimal distroless base with no shell or package manager.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
EXPOSE 8081
ENV HTTP_ADDR=:8081
ENTRYPOINT ["/api"]
