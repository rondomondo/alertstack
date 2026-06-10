# syntax=docker/dockerfile:1

FROM golang:1.24

WORKDIR /app

COPY go.mod go.sum ./
RUN GOTOOLCHAIN=auto go mod download

COPY *.go ./
COPY certs/ certs/

RUN CGO_ENABLED=0 GOOS=linux GOTOOLCHAIN=auto go build -o /pingpong ./pingpong.go

ENV DOMAINNAME="example.com"
ENV PORT=8090
ENV PORT_TLS=8443

EXPOSE 8090 8443

ENTRYPOINT ["/pingpong"]
CMD ["-port", "8090", "-port-tls", "8443"]
