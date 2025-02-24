FROM trivialsec/node-base

WORKDIR /srv/app

USER root
COPY install-google-chrome.sh install-google-chrome.sh
RUN bash install-google-chrome.sh && \
    wget -q http://repo.mysql.com/RPM-GPG-KEY-mysql -O /tmp/mysql.key && \
    rpm --import /tmp/mysql.key && \
    yum install -q -y https://repo.mysql.com/mysql80-community-release-el7-1.noarch.rpm && \
    amazon-linux-extras enable python3 >/dev/null && \
    yum install -q -y \
        python38 \
        python38-pip \
        python38-devel \
        mysql-connector-python \
        PyYAML && \
    yum clean metadata && \
    yum -q -y clean all && \
    python3 -m pip install -q --no-cache-dir -U pip && \
    python3 -m pip install -q --no-cache-dir -U setuptools wheel

COPY src src

USER ec2-user
ENTRYPOINT ["/usr/bin/python3"]
CMD ["src/main.py"]
