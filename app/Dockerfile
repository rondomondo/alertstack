# syntax=docker/dockerfile:1

FROM golang:1.20.3

# Set destination for COPY
WORKDIR /app

RUN mkdir certs
# Copy the source code. Note the slash at the end, as explained in
# https://docs.docker.com/engine/reference/builder/#copy
COPY *.go ./
COPY certs/alertstack.* certs/

RUN go mod init server
RUN go mod tidy

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -o /pingpong

ENV DOMAINNAME "example.com"
ENV PORT=8090
ENV PORT_TLS=8443

COPY generate-cert.sh /tmp/generate-cert.sh 
RUN [ "/tmp/generate-cert.sh", "$DOMAINNAME" ]

# Optional:
# To bind to a TCP port, runtime parameters must be supplied to the docker command.
# But we can document in the Dockerfile what ports
# the application is going to listen on by default.
# https://docs.docker.com/engine/reference/builder/#expose

ENV PORT=8090
ENV PORT_TLS=8443

EXPOSE $PORT $PORT_TLS
    
ENTRYPOINT [ "/pingpong" ]
# Run
CMD  [ "-port", $PORT, "-port-tls", "${PORT_TLS}" ]
