FROM alpine:3.20 AS microsocks
ARG MICROSOCKS_VERSION=1.0.5
RUN apk add --no-cache build-base \
 && wget -qO- https://github.com/rofl0r/microsocks/archive/refs/tags/v${MICROSOCKS_VERSION}.tar.gz | tar xz \
 && make -C microsocks-${MICROSOCKS_VERSION} \
 && install -m 755 microsocks-${MICROSOCKS_VERSION}/microsocks /usr/local/bin/microsocks

FROM alpine:3.20
RUN apk add --no-cache bash openssh-client
COPY --from=microsocks /usr/local/bin/microsocks /usr/local/bin/microsocks
COPY entrypoint.sh README.md remote/bootstrap.sh.tmpl /app/
RUN chmod +x /app/entrypoint.sh
VOLUME /data
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
