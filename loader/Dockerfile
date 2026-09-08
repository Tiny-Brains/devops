# syntax=docker/dockerfile:1

# THE ONE LOADER. A one-shot that does to the running stack everything that is not "run a server":
# declares the deployment facts in the database, makes the replay bucket, and installs the three
# packages into the one Orion by running each repo's own scripts/load-package.sh against it. The
# repos are mounted read-only at /pkg/<name>; this image carries no package of its own.
#
# curl drives the admin API and the S3 API (bucket creation is a sigv4 PUT -- no `mc`), jq reads
# ids out of the definitions, psql writes the deployment facts.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl jq postgresql16-client

COPY run.sh /usr/local/bin/loader
RUN chmod +x /usr/local/bin/loader

ENTRYPOINT ["/usr/local/bin/loader"]
CMD ["all"]
