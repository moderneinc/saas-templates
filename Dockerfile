FROM alpine:3.21

RUN apk add --no-cache \
    aws-cli \
    bash \
    curl \
    jq

WORKDIR /app

COPY sync-audit-logs.sh backfill-audit-logs.sh push-to-s3.sh entrypoint.sh ./
RUN chmod +x sync-audit-logs.sh backfill-audit-logs.sh push-to-s3.sh entrypoint.sh

# Persistent volumes for state and output
VOLUME ["/app/state", "/app/output", "/app/archive"]

ENV SYNC_INTERVAL_MINUTES=15
ENV POLL_INTERVAL=5
ENV POLL_TIMEOUT=120
ENV OUTPUT_DIR=/app/output
ENV STATE_DIR=/app/state
ENV ARCHIVE_DIR=/app/archive

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["cron"]
