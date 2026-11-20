FROM reg.hrlyit.com/library/node:24-bookworm AS build
ENV PNPM_HOME=/pnpm
ENV PATH=/pnpm:$PATH
RUN corepack enable
WORKDIR /src

RUN sed -i 's#deb.debian.org#mirrors.ustc.edu.cn#g' /etc/apt/sources.list.d/debian.sources
# The mirror is reachable directly. Keep the connection count low so the mirror does not
# throttle the burst, and raise the default 30s acquire timeout that aborts slow transfers.
RUN printf 'Acquire::http::Proxy "false";\nAcquire::http::Timeout "120";\nAcquire::Retries "5";\nAcquire::http::Pipeline-Depth "0";\n' > /etc/apt/apt.conf.d/99mirror
RUN apt-get update \
 && apt-get -o APT::Acquire::Queue-Mode=access -o Acquire::Queue-Mode=access -o Acquire::http::Pipeline-Depth=0 install -y --no-install-recommends musl-tools \
 && rm -rf /var/lib/apt/lists/*

COPY . .

# Stamped into the browser bundle; git is not available here, so pass it in.
ARG DSH_CLIENT_COMMIT_HASH
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH}

# The registry mirror is reachable directly; Docker's build proxy resets bursts of connections.
RUN npm config set noproxy registry.npmmirror.com && \
    printf 'noproxy=registry.npmmirror.com\n' > .npmrc
RUN --mount=type=cache,target=/pnpm/store pnpm install --frozen-lockfile
RUN pnpm run build:artifacts      # native addons + tsc/tsdown lib + web frontend dist
RUN pnpm --dir native/system run build:native
# Pinned Python/Node payload for PTC, workspace-dependency tools, and the Office skills.
# Writes primary-runtime/ and office-skills/ under /opt/dsh-office.
# files.pythonhosted.org is throttled on some networks, so the locked wheels are fetched from
# a PyPI mirror into the SHA-256-addressed download cache first; the builder still verifies every
# digest. The Python and Node archives come from GitHub and nodejs.org through the build proxy.
ARG PYPI_MIRROR=https://pypi.tuna.tsinghua.edu.cn
# ARG PYPI_MIRROR=https://mirrors.ustc.edu.cn/pypi/simple
ENV PYPI_MIRROR=${PYPI_MIRROR}
RUN node --input-type=module -e "import fs from 'node:fs'; import crypto from 'node:crypto'; const lock = JSON.parse(fs.readFileSync('scripts/primary-runtime/lock.json', 'utf8')); fs.mkdirSync('/tmp/dsh-downloads', { recursive: true }); for (const wheel of [...lock.wheels, ...lock.targets['linux-x64'].wheels]) { const bytes = Buffer.from(await (await fetch(wheel.url.replace('https://files.pythonhosted.org', process.env.PYPI_MIRROR), { signal: AbortSignal.timeout(300000) })).arrayBuffer()); if (crypto.createHash('sha256').update(bytes).digest('hex') !== wheel.sha256) throw new Error('checksum mismatch: ' + wheel.url); fs.writeFileSync('/tmp/dsh-downloads/' + wheel.sha256, bytes); }"
# Each finished download stays in the cache, so a retry after a stalled transfer resumes at the next archive.

# 代理窗口只覆盖本步，下载完立即关闭
ENV http_proxy=http://10.80.30.178:8888 \
    https_proxy=http://10.80.30.178:8888 \
    no_proxy=localhost,127.0.0.1,10.80.30.178,reg.hrlyit.com,.hrlyit.com,mirrors.tuna.tsinghua.edu.cn,pypi.tuna.tsinghua.edu.cn,registry.npmmirror.com

RUN export NODE_USE_ENV_PROXY=1 CI=true DSH_RESOURCE_DOWNLOAD_TIMEOUT_MS=120000; \
    for attempt in 1 2 3 4 5; do \
      pnpm run prepare:primary-runtime --target linux-x64 --output /opt/dsh-office --cache /tmp/dsh-downloads --python-only && break; \
      [ "$attempt" -lt 5 ] || exit 1; \
    done; \
    rm -rf /tmp/dsh-downloads

ENV http_proxy= \
    https_proxy= \
    no_proxy=

# Runs after every build and prepare step, since those need devDependencies (tsx, tsc, tsdown).
# RUN export CI=true; pnpm prune --prod --ignore-scripts \
#  && find /src /opt/dsh-office -type f \( -name '*.map' -o -name '*.tsbuildinfo' -o -name '*.pyc' \) -delete \
#  && find /opt/dsh-office -type d -name '__pycache__' -prune -exec rm -rf {} +

FROM reg.hrlyit.com/library/node:24-bookworm-slim
WORKDIR /src

# git: workspace changes panel and repository work by users.
# bubblewrap: the bwrap sandbox rung (needs user namespaces, see above).
RUN sed -i 's#deb.debian.org#mirrors.ustc.edu.cn#g' /etc/apt/sources.list.d/debian.sources
RUN printf 'Acquire::http::Proxy "false";\nAcquire::http::Timeout "120";\nAcquire::Retries "5";\nAcquire::http::Pipeline-Depth "0";\n' > /etc/apt/apt.conf.d/99mirror
RUN apt-get update \
 && apt-get -o APT::Acquire::Queue-Mode=access -o Acquire::Queue-Mode=access -o Acquire::http::Pipeline-Depth=0 install -y --no-install-recommends bubblewrap git ca-certificates \
  libreoffice-writer \
  fonts-noto-cjk \
  poppler-utils \
  locales \
  neovim \
 && sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /src /src
COPY --from=build /opt/dsh-office /opt/dsh-office

ENV PATH=/opt/dsh-office/primary-runtime/dependencies/python/bin:$PATH
RUN pip install --no-cache-dir httpx

# Fail the build rather than ship an image whose Linux sandbox rungs cannot exist.
RUN set -eux; \
    cd /src/packages/sandbox/sandbox-local; \
    node --input-type=module -e "const m=await import('@deepseek-ai/node-addon-system/landlock-run');const fs=await import('node:fs');const p=m.launcherPath();console.log('landlock launcher:',p,'present:',fs.existsSync(p));if(!fs.existsSync(p))throw new Error('landlock-run is not resolvable at '+p)"; \
    bwrap --version

USER 1000:1000
ENV HOME=/home/dsh \
    DSH_HOME=/home/dsh/.dsh \
    DSH_PRIMARY_RUNTIME=/opt/dsh-office/primary-runtime \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8

EXPOSE 3080
ENTRYPOINT ["node", "/src/apps/cli/lib/bin.js"]
CMD ["--profile", "web", "--no-open"]
