# The stand-in ERP: PostgreSQL with the Chinook sample data, the detection rules and the
# fix functions. Chinook is fetched at build time and pinned by checksum, not vendored.
FROM postgres:17-alpine@sha256:e5d2edd28b1f8d40a0a6c0c9cdc545b19b56a0d5d88f94bc11a97d970d4700d0
# Take the base image's pending security updates, and drop gosu: it only serves the
# entrypoint's root-to-postgres step, and this image never runs as root.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && rm /usr/local/bin/gosu
# Fetched and verified in a RUN step: Dagger's Dockerfile build does not support ADD --checksum.
RUN wget -q -O /docker-entrypoint-initdb.d/10-chinook.sql \
      https://github.com/lerocha/chinook-database/releases/download/v1.4.5/Chinook_PostgreSql.sql \
    && printf '%s  %s\n' e3fde5c1a5b51a2a91429a702c9ca6e69ba56e6c7f5e112724d70c3d03db695e /docker-entrypoint-initdb.d/10-chinook.sql > /tmp/sum \
    && sha256sum -c /tmp/sum && rm /tmp/sum \
    && chmod 644 /docker-entrypoint-initdb.d/10-chinook.sql
COPY 20-rules.sql 30-roles.sh /docker-entrypoint-initdb.d/
USER postgres
