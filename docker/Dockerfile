FROM python:3.12-slim-bookworm

LABEL description="Kolla-Ansible deploy container for OpenStack Flamingo (2025.2)"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /kolla

RUN pip install --upgrade pip && \
    pip install \
      kolla-ansible==21.0.0 \
      python-openstackclient \
      ansible-core \
      jmespath

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      sshpass \
      git \
      vim \
      curl \
      iputils-ping \
      openssh-client && \
    rm -rf /var/lib/apt/lists/*

# Cài Ansible Galaxy deps cho Kolla
RUN kolla-ansible install-deps

# Khởi tạo cấu hình Kolla mặc định
RUN mkdir -p /etc/kolla && \
    cp -r $(python3 -c "import site; print(site.getsitepackages()[0])")/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
