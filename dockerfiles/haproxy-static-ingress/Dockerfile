FROM haproxy:1.9.4-alpine

EXPOSE 4500

RUN addgroup -S haproxy && \
    adduser  -S -G haproxy haproxy && \
    apk add --no-cache gettext

WORKDIR /tmp

USER haproxy

COPY . /tmp

ENTRYPOINT ["/tmp/docker-entrypoint.sh"]
