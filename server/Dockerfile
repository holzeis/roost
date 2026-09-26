# --platform=$BUILDPLATFORM pins this stage to the runner's own
# architecture (amd64) regardless of which arch this image is being built
# for — Go already cross-compiles natively via GOARCH below, so there's no
# reason to run the actual compile step under QEMU emulation for arm64,
# which is dramatically slower than a native compile. Only the tiny final
# stage below needs to "be" the target architecture, and that's just a
# binary COPY — instant either way, emulated or not.
FROM --platform=$BUILDPLATFORM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
# Cache mounts persist the module/build cache across builds (via CI's
# cache-to/cache-from: type=gha) independently of Docker's own layer
# cache — the layer cache alone can't help go build reuse unchanged
# dependencies' compiled output once COPY . . below invalidates on every
# commit that touches any source file, which is effectively every commit.
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
ARG TARGETOS=linux
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -o /out/roost-server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/roost-server /roost-server
USER nonroot:nonroot
ENTRYPOINT ["/roost-server"]
