# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ARG UID=1000
ARG GID=1000
ARG USER=builder

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    USE_CCACHE=1 \
    CCACHE_EXEC=/usr/bin/ccache \
    CCACHE_DIR=/home/builder/.ccache

# Base tools + LineageOS build deps (from LineageOS Wiki)
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata sudo ca-certificates curl wget git git-lfs gnupg \
    bc bison build-essential ccache flex g++-multilib gcc-multilib \
    gperf imagemagick protobuf-compiler python3 python3-protobuf python-is-python3 \
    lib32readline-dev lib32z1-dev libdw-dev libelf-dev libgnutls28-dev \
    lz4 libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync \
    schedtool squashfs-tools xsltproc zip zlib1g-dev \
    file unzip openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && locale-gen en_US.UTF-8

# ncurses workaround:
# - Ubuntu 23.10+ : install libtinfo5/libncurses5 from Ubuntu 23.04 debs (as per LineageOS Wiki)
# - Older         : install lib32ncurses5-dev libncurses5 libncurses5-dev
RUN . /etc/os-release && \
    if dpkg --compare-versions "$VERSION_ID" ge "23.10"; then \
      apt-get update && apt-get install -y --no-install-recommends dpkg && \
      wget -q https://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb && \
      wget -q https://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2_amd64.deb && \
      dpkg -i libtinfo5_6.3-2_amd64.deb libncurses5_6.3-2_amd64.deb || apt-get -f install -y && \
      rm -f libtinfo5_6.3-2_amd64.deb libncurses5_6.3-2_amd64.deb && \
      rm -rf /var/lib/apt/lists/*; \
    else \
      apt-get update && apt-get install -y --no-install-recommends \
        lib32ncurses5-dev libncurses5 libncurses5-dev \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Create a non-root user matching host UID/GID (so bind mounts won't become root-owned)
RUN groupadd -g ${GID} ${USER} && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USER} \
 && echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER} \
 && chmod 0440 /etc/sudoers.d/${USER}

USER ${USER}
WORKDIR /home/${USER}

ENV PATH="/home/${USER}/bin:${PATH}"

CMD ["/bin/bash"]
