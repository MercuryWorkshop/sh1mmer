# Minimal Dockerfile to provide a reproducible environment for running wax tooling (linting, helper scripts)
# Note: Running wax on images requires privileged access to loop devices and filesystem tools; running inside a container may need extra privileges (--privileged) and device mounts.

FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    wget \
    curl \
    gdisk \
    util-linux \
    e2fsprogs \
    pv \
    tar \
    coreutils \
    ca-certificates \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY . /workspace

# Make sure scripts are executable
RUN chmod +x /workspace/wax/*.sh || true
RUN chmod +x /workspace/tools/*.sh || true

ENTRYPOINT ["/bin/bash"]
