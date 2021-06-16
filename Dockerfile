ARG UBUNTU_VERSION=18.04
FROM ubuntu:${UBUNTU_VERSION}

# URL to node.js binaries
ARG NODE_URL=https://nodejs.org/dist/v12.16.1/node-v12.16.1-linux-x64.tar.xz
# Fixed docker client version. To find available version execute `apt-get update && apt-cache madison docker-ce-cli`
ARG DOCKER_VERSION=5:19.03.8~3-0~ubuntu-bionic
# Fixed docker compose version. To find latest version visit: https://github.com/docker/compose/releases/latest
ARG DOCKER_COMPOSE=1.25.4

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    apt-transport-https ca-certificates curl gnupg-agent software-properties-common \
    sshfs xz-utils jq tree mysql-client \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - \
  && add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli="${DOCKER_VERSION}" \
  && rm -rf /var/lib/apt/lists/* /tmp/*

RUN curl -sL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose \
  && chmod +x /usr/local/bin/docker-compose

ENV PATH="/opt/tools/bin:/opt/node/active/bin:${PATH}"
RUN mkdir /opt/node \
  && cd /opt/node \
  && curl -Os "${NODE_URL}" \
  && tar -xf "$(basename "${NODE_URL}")" \
  && rm "$(basename "${NODE_URL}")" \
  && ln -s "$(find . -maxdepth 1 -name 'node-*' -type d)" active \
  && npm i -g  @profiprog/label-process-output@1.1.1 \
  && rm -fr ~/.config ~/.npm

RUN mkdir ~/.ssh \
  && chmod 0700 ~/.ssh \
  && ln -nfs /var/cache/backup/known_hosts ~/.ssh/known_hosts
WORKDIR /tmp
VOLUME /var/cache/backup
ENV HOOKS="$HOME/hooks"

COPY . /opt/tools
ENTRYPOINT ["/opt/tools/entrypoint.sh"]

