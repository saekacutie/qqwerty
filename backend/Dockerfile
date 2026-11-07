FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum main.go ./
RUN go mod download
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/control-backend .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/control-backend /control-backend
EXPOSE 8081
USER nonroot:nonroot
ENTRYPOINT ["/control-backend"]