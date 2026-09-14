FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS=linux
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -o /out/roost-server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/roost-server /roost-server
USER nonroot:nonroot
ENTRYPOINT ["/roost-server"]
