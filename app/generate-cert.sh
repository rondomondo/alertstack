#!/bin/bash

if [ $# -eq 1 ]; then 
    DOMAINNAME="$1"
else 
    DOMAINNAME="pingpong.com"
fi

openssl genrsa -des3 -passout pass:x -out server.pass.key 2048
openssl rsa -passin pass:x -in server.pass.key -out server.key
rm server.pass.key
openssl req -new -key server.key -out server.csr \
    -subj "/C=SG/ST=Singapore/L=Singapore/O=SRE@Company/OU=SRE/CN=${DOMAINNAME}"
openssl x509 -req -days 365 -in server.csr -signkey server.key -out server.crt

echo

openssl genrsa -des3 -passout pass:x -out ${DOMAINNAME}.pass.key 2048
openssl rsa -passin pass:x -in ${DOMAINNAME}.pass.key -out ${DOMAINNAME}.key
rm ${DOMAINNAME}.pass.key
openssl req -new -key ${DOMAINNAME}.key -out ${DOMAINNAME}.csr \
    -subj "/C=SG/ST=Singapore/L=Singapore/O=SRE@Company/OU=SRE/CN=${DOMAINNAME}"
openssl x509 -req -days 365 -in ${DOMAINNAME}.csr -signkey ${DOMAINNAME}.key -out ${DOMAINNAME}.crt
