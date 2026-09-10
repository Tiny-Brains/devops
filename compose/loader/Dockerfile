# syntax=docker/dockerfile:1

# A one-shot that does to the running stack everything that is not "run a server": declares the
# deployment facts, makes the buckets, and installs each package by running that repo's own
# scripts/load-package.sh. The repos are mounted read-only at /pkg/<name>; this image carries none.
#
# curl drives the admin and S3 APIs (bucket creation is a sigv4 PUT -- no `mc`), jq reads ids out of
# the definitions, psql writes the deployment facts.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl jq postgresql16-client

COPY run.sh /usr/local/bin/loader
RUN chmod +x /usr/local/bin/loader

ENTRYPOINT ["/usr/local/bin/loader"]
CMD ["all"]
