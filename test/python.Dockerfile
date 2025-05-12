# tested with ubuntu:24.04, debian:stable-slim, almalinux:8,
# opensuse/leap:latest
ARG baseimage
FROM ${baseimage:-ubuntu:24.04}

# As per uv's specification
ARG PYTHON_VERSION
ENV PYTHON_VERSION=${PYTHON_VERSION:-3.13}
ENV VENV_DIR=/opt/venv

ARG packages
RUN if apt-get --help 2>/dev/null >/dev/null; then \
      apt-get update && \
      apt-get install -y \
      curl \
      $packages \
      && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* && \
    true; elif yum --help 2>/dev/null >/dev/null; then \
      yum install -y \
      curl \
      $packages \
      && \
      yum clean all && \
    true; else \
      zypper install -y \
      curl \
      gzip \
      tar \
      $packages \
      && \
      zypper clean --all && \
    true; fi && \
    rm -rf /tmp/* /var/tmp/* /var/cache/*

ENV PATH="$VENV_DIR/bin:$PATH"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    /root/.local/bin/uv venv --python $PYTHON_VERSION $VENV_DIR && \
    python -m ensurepip && \
    ln -s "$VENV_DIR/bin/pip3" "$VENV_DIR/bin/pip" && \
    find / -xdev -name __pycache__ -type d -exec rm -r {} \+ && \
    rm /root/.local/bin/uv*

RUN echo 'PATH="'$VENV_DIR'/bin:$PATH"' >> /etc/profile

CMD ["python"]
