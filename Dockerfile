FROM httpd:2.4-alpine

RUN apk add --no-cache git git-daemon openssl curl \
    && mkdir -p /srv/git /srv/www \
    && chown root:daemon /srv/git \
    && chmod 0750 /srv/git \
    && ln -s "$(git --exec-path)/git-http-backend" /usr/local/apache2/cgi-bin/git-http-backend \
    && git config --system http.receivepack false \
    && git config --system http.uploadpack true \
    && git config --system --add safe.directory /srv/git/fixture.git

COPY httpd-fixture.conf /usr/local/apache2/conf/httpd.conf
COPY health.html /srv/www/health.html
COPY start.sh /usr/local/bin/fixture-start
RUN chmod 0755 /usr/local/bin/fixture-start \
    && chmod 0644 /srv/www/health.html

ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD curl --disable --fail --silent --output /dev/null http://127.0.0.1:8080/health.html || exit 1
ENTRYPOINT ["/usr/local/bin/fixture-start"]
