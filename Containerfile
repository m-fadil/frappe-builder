ARG PYTHON_VERSION=3.14
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG INSTALL_CHROMIUM=true

ARG NODE_VERSION=24
ENV NVM_DIR=/home/frappe/.nvm
ENV NVM_SYMLINK_CURRENT=true
ENV PATH=${NVM_DIR}/current/bin/:${PATH}

RUN useradd -ms /bin/bash frappe \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    curl \
    aria2 \
    git \
    vim \
    nginx \
    gettext-base \
    file \
    # weasyprint dependencies
    libpango-1.0-0 \
    libharfbuzz0b \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    # For backups
    restic \
    gpg \
    # MariaDB
    mariadb-client \
    less \
    # Postgres
    libpq-dev \
    postgresql-client \
    # For healthcheck
    wait-for-it \
    jq \
    # For MIME type detection
    media-types \
    # NodeJS
    && mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use ${NODE_VERSION} \
    && npm install -g yarn \
    && corepack enable pnpm \
    && nvm alias default ${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >>/home/frappe/.bashrc \
    # Install wkhtmltopdf with patched qt
    && if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; fi \
    && if [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && downloaded_file=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
    && curl -sLO https://github.com/wkhtmltopdf/packaging/releases/download/$WKHTMLTOPDF_VERSION/$downloaded_file \
    && apt-get install -y ./$downloaded_file \
    && rm $downloaded_file \
    # Chromium
    && if [ "$INSTALL_CHROMIUM" != "false" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        chromium-headless-shell; \
    fi \
    # Clean up
    && rm -rf /var/lib/apt/lists/* \
    && rm -fr /etc/nginx/sites-enabled/default \
    && mkdir -p /etc/nginx/snippets \
    && pip3 install frappe-bench \
    # Fixes for non-root nginx and logs to stdout
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log \
    && touch /run/nginx.pid \
    && chown -R frappe:frappe /etc/nginx/conf.d \
    && chown -R frappe:frappe /etc/nginx/nginx.conf \
    && chown -R frappe:frappe /etc/nginx/snippets \
    && chown -R frappe:frappe /var/log/nginx \
    && chown -R frappe:frappe /var/lib/nginx \
    && chown -R frappe:frappe /run/nginx.pid

# Kept after the apt layers on purpose: COPY invalidates cache on content
# change, so editing an nginx file here only rebuilds these small layers
# instead of the whole apt/node/chromium install above.
COPY resources/core/nginx/nginx-template.conf /templates/nginx/frappe.conf.template
COPY resources/core/nginx/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
COPY resources/core/nginx/security_headers.conf /etc/nginx/snippets/security_headers.conf
RUN chmod 755 /usr/local/bin/nginx-entrypoint.sh \
    && chmod 644 /templates/nginx/frappe.conf.template


FROM base AS builder

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    # For frappe framework
    wget \
    #for building arm64 binaries
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    # For psycopg2
    libpq-dev \
    # Other
    libffi-dev \
    liblcms2-dev \
    libldap2-dev \
    libmariadb-dev \
    libsasl2-dev \
    libtiff5-dev \
    libwebp-dev \
    pkg-config \
    redis-tools \
    rlwrap \
    tk8.6-dev \
    cron \
    # For pandas
    gcc \
    build-essential \
    libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

FROM builder AS framework

USER frappe

ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG FRAPPE_CACHE_BUST=""

# `: "${FRAPPE_CACHE_BUST}"` is a no-op that pulls the ARG into this RUN's cache
# key. Without it BuildKit reuses this layer even when the Frappe branch moved
# upstream. Deliberately separate from APPS_CACHE_BUST below: bumping this one
# does not touch the `apps` stage, and vice versa — updating one custom app no
# longer forces a re-clone of the Frappe framework itself.
RUN --mount=type=cache,target=/home/frappe/.cache/uv,uid=1000,gid=1000 \
  --mount=type=cache,target=/home/frappe/.cache/pip,uid=1000,gid=1000 \
  --mount=type=cache,target=/home/frappe/.cache/yarn,uid=1000,gid=1000 \
  : "${FRAPPE_CACHE_BUST}" && \
  bench init \
    --frappe-branch=${FRAPPE_BRANCH} \
    --frappe-path=${FRAPPE_PATH} \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    --skip-assets \
    --verbose \
    /home/frappe/frappe-bench && \
  cd /home/frappe/frappe-bench && \
  echo "{}" > sites/common_site_config.json && \
  find apps -mindepth 1 -path "*/.git" -type d -prune -exec rm -rf {} +

FROM framework AS apps

ARG APPS_CACHE_BUST=""

# `: "${APPS_CACHE_BUST}"` pulls the ARG into this RUN's cache key for the same
# reason as FRAPPE_CACHE_BUST above, scoped to apps.json instead of Frappe.
# `bench get-app` is looped explicitly (rather than `bench init --apps_path=`)
# so this clone+install step lands in its own stage/layer, separate from the
# Frappe framework bootstrap in the `framework` stage above.
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json,uid=1000,gid=1000 \
  --mount=type=secret,id=netrc,target=/home/frappe/.netrc,uid=1000,gid=1000,mode=0600 \
  --mount=type=cache,target=/home/frappe/.cache/uv,uid=1000,gid=1000 \
  --mount=type=cache,target=/home/frappe/.cache/pip,uid=1000,gid=1000 \
  --mount=type=cache,target=/home/frappe/.cache/yarn,uid=1000,gid=1000 \
  : "${APPS_CACHE_BUST}" && \
  cd /home/frappe/frappe-bench && \
  if [ -f /opt/frappe/apps.json ] && [ -s /opt/frappe/apps.json ]; then \
    jq -c '.[]' /opt/frappe/apps.json | while IFS= read -r app; do \
      url=$(echo "$app" | jq -r '.url') && \
      branch=$(echo "$app" | jq -r '.branch // empty') && \
      branch_flag="" && \
      if [ -n "$branch" ]; then branch_flag="--branch $branch"; fi && \
      bench get-app $branch_flag --skip-assets "$url"; \
    done; \
  fi && \
  BENCH_DEVELOPER=1 bench build && \
  find apps -mindepth 1 -path "*/.git" -type d -prune -exec rm -rf {} +

FROM base AS backend

USER frappe

COPY --from=apps --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# Move assets to image-layer storage
#
# Also pre-create shared-assets as frappe:frappe here: Docker seeds a *new*
# named volume from whatever exists at its mount path in the image at first
# mount. This path has no other image-layer content, so without an owned
# placeholder directory the volume is created with root ownership and
# main-entrypoint.sh's merge `cp` fails with "Permission denied" for the
# frappe user at runtime.
RUN cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/assets && \
  rm -rf /home/frappe/frappe-bench/sites/assets && \
  mkdir -p /home/frappe/frappe-bench/shared-assets
VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs", \
  "/home/frappe/frappe-bench/shared-assets" \
]

USER root
# This entrypoint script link build assets of the image to the mounted sites volume at container initialization
COPY resources/core/main-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

COPY resources/core/start.sh /usr/local/bin/start.sh
RUN chmod 755 /usr/local/bin/start.sh

USER frappe
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["start.sh"]
