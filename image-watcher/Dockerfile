# Tiny image for the image-watcher CronJob (see k8s/image-watcher.yaml):
# curl + jq + kubectl, nothing else. Tools are installed at build time (root
# is normal/unavoidable during `docker build` — that's not the same thing as
# the container running as root) and the image then switches to a non-root
# user for good — this project's k8s workloads never run as root, even
# short-lived ones.
#
# USER must be the numeric UID, not the name ("watcher") — the CronJob sets
# securityContext.runAsNonRoot: true, and the container runtime can only
# verify that against a numeric UID baked into the image; a named user fails
# with "cannot verify user is non-root" (CreateContainerConfigError) before
# the container ever starts.
FROM alpine:3.24
RUN apk add --no-cache curl jq kubectl && \
    adduser -D -u 1000 watcher
COPY check.sh /usr/local/bin/check.sh
RUN chmod +x /usr/local/bin/check.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/check.sh"]
