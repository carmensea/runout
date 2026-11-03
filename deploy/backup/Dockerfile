# Railway Cron job (docs/railway-deployment.md §7). Runs once, then exits.
# postgres:18 brings pg_dump, pg_restore and a server for the disposable restore check.
FROM postgres:18
RUN apt-get update -qq && apt-get install -y --no-install-recommends git openssh-client openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY backup.sh /usr/local/bin/backup.sh
COPY known_hosts /etc/ssh/ssh_known_hosts
USER postgres
ENV HOME=/tmp
ENTRYPOINT []
# A hung run would make Railway skip later ones, so it can't outlive 30 minutes.
CMD ["timeout", "--signal=TERM", "1800", "/usr/local/bin/backup.sh"]
