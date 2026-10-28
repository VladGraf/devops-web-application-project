FROM docker:27.5.1-cli-alpine3.21
RUN apk add --no-cache bash curl ca-certificates python3 py3-pip jq coreutils git
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/final-project-tools \
    && /opt/final-project-tools/bin/pip install --no-cache-dir --only-binary=:all: -r /tmp/requirements.txt
ENV PATH="/opt/final-project-tools/bin:${PATH}"
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in amd64|arm64) ;; *) echo "Unsupported architecture: $TARGETARCH"; exit 1;; esac; \
    curl -fsSL "https://github.com/k3d-io/k3d/releases/download/v5.8.3/k3d-linux-${TARGETARCH}" -o /usr/local/bin/k3d; \
    curl -fsSL "https://dl.k8s.io/release/v1.31.7/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl; \
    curl -fsSL "https://dl.k8s.io/release/v1.31.7/bin/linux/${TARGETARCH}/kubectl.sha256" -o /tmp/kubectl.sha256; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/k3d /usr/local/bin/kubectl
WORKDIR /project
ENTRYPOINT ["/bin/bash"]
