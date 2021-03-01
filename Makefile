SHELL := /bin/bash
include .env
export $(shell sed 's/=.*//' .env)

.PHONY: help

help: ## This help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

CMD_AWS := aws
ifdef AWS_PROFILE
CMD_AWS += --profile $(AWS_PROFILE)
endif
ifdef AWS_REGION
CMD_AWS += --region $(AWS_REGION)
endif

prep:
	mkdir -p worker_datadir mysql_datadir redis_datadir
	find . -type f -name '*.pyc' -delete 2>/dev/null || true
	find . -type d -name '__pycache__' -delete 2>/dev/null || true
	find . -type f -name '*.DS_Store' -delete 2>/dev/null || true

wheel: prep
	rm -rf common/build common/dist common/trivialsec_common.egg-info web/docker/build workers/docker/build web/docker/packages workers/docker/packages
	pip uninstall -y trivialsec-common || true
	cd common; python3.8 setup.py check && pip --no-cache-dir wheel --wheel-dir=build/wheel -r requirements.txt && \
		python3.8 setup.py bdist_wheel --universal
	pip install --no-cache-dir --find-links=common/build/wheel --no-index common/dist/trivialsec_common-*-py2.py3-none-any.whl
	cp -r common/build/wheel web/docker/build
	cp common/dist/trivialsec_common-*.whl web/docker/build/
	cp -r common/build/wheel workers/docker/build
	cp common/dist/trivialsec_common-*.whl workers/docker/build/

watch:
	while [[ 1 ]]; do inotifywait -e modify --exclude build common/setup.py ; make build-wheel && make rebuild-workers && make run-workers && docker-compose build --compress web && make run-web ; done

install-dev:
	pip install -q -U pip setuptools pylint wheel awscli
	pip install -q -U --no-cache-dir --isolated -r ./common/requirements.txt
	pip install -q -U --no-cache-dir --isolated -r ./web/docker/requirements.txt
	pip install -q -U --no-cache-dir --isolated -r ./workers/docker/requirements.txt

lint:
	cd workers/src; pylint --jobs=0 --persistent=y --errors-only **/*.py
	cd web/src; pylint --jobs=0 --persistent=y --errors-only **/*.py

update:
	git pull
	docker-compose pull redis mongo mysql

build-runner:
	docker-compose build --no-cache --compress gitlab-runner

buildnc-base:
	docker-compose build --no-cache --compress python-base
	docker tag $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com/trivialsec/python-base trivialsec/python-base
	docker-compose build --no-cache --compress node-base
	docker tag $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com/trivialsec/node-base trivialsec/node-base

build-base:
	docker-compose build --compress python-base
	docker tag $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com/trivialsec/python-base trivialsec/python-base
	# docker-compose build --compress node-base
	# docker tag $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com/trivialsec/node-base trivialsec/node-base

build: package
	docker-compose build --compress web sockets workers

buildnc: buildnc-base package
	docker-compose build --no-cache --compress web sockets workers

rebuild: down build

docker-clean:
	docker rmi $(docker images -qaf "dangling=true")
	yes | docker system prune
	sudo service docker restart

docker-purge:
	docker rmi $(docker images -qa)
	yes | docker system prune
	sudo service docker stop
	sudo rm -rf /tmp/docker.backup/
	sudo cp -Pfr /var/lib/docker /tmp/docker.backup
	sudo rm -rf /var/lib/docker
	sudo service docker start

db-create: down
	docker-compose exec mysql bash -c "mysql -uroot -p'$(MYSQL_ROOT_PASSWORD)' -q -s < /tmp/sql/schema.sql"
	docker-compose exec mysql bash -c "mysql -uroot -p'$(MYSQL_ROOT_PASSWORD)' -q -s < /tmp/sql/init-data.sql"

db-rebuild: down
	docker-compose up -d mysql
	sleep 5
	docker-compose exec mysql bash -c "mysql -uroot -p'$(MYSQL_ROOT_PASSWORD)' -q -s < /tmp/sql/drop-tables.sql"
	docker-compose exec mysql bash -c "mysql -uroot -p'$(MYSQL_ROOT_PASSWORD)' -q -s < /tmp/sql/schema.sql"
	docker-compose exec mysql bash -c "mysql -uroot -p'$(MYSQL_ROOT_PASSWORD)' -q -s < /tmp/sql/init-data.sql"

run: prep
	docker-compose up web sockets workers

up: prep
	docker-compose up -d web sockets workers

down:
	docker-compose stop web sockets workers
	yes|docker-compose rm web sockets workers

package: wheel
	mkdir -p $(PKG_PATH) common/build/wheel workers/build/nmap/scripts workers/build/nmap/nselib/data
	rm -f $(PKG_PATH)/*.zip workers/docker/packages/*.zip web/docker/packages/*.zip
	zip -9rq $(PKG_PATH)/build.zip common/build/wheel
	zip -9rq $(PKG_PATH)/sockets.zip sockets/src -x '*.pyc' -x '__pycache__' -x '*.DS_Store'
	zip -uj9q $(PKG_PATH)/sockets.zip sockets/package.json sockets/docker/run.sh
	zip -9rq $(PKG_PATH)/web.zip web/src -x '*.pyc' -x '__pycache__' -x '*.DS_Store'
	zip -uj9q $(PKG_PATH)/web.zip web/docker/requirements.txt
	zip -9rq $(PKG_PATH)/worker.zip workers/src workers/bin -x '*.pyc' -x '__pycache__' -x '*.DS_Store'
	zip -uj9q $(PKG_PATH)/worker.zip workers/docker/circus.ini workers/docker/circusd-logger.yaml workers/docker/requirements.txt
	wget -q https://github.com/OWASP/Amass/releases/download/v$(AMASS_VERSION)/amass_linux_amd64.zip -O $(PKG_PATH)/amass_linux_amd64.zip
	wget -q https://testssl.sh/$(OPENSSL_PKG) -O $(PKG_PATH)/$(OPENSSL_PKG)
	tar xvzf $(PKG_PATH)/$(OPENSSL_PKG)
	mv bin/openssl.Linux.x86_64.static bin/openssl
	wget -q https://raw.githubusercontent.com/drwetter/testssl.sh/3.1dev/testssl.sh -O $(PKG_PATH)/testssl
	chmod a+x $(PKG_PATH)/testssl
	mkdir -p $(PKG_PATH)/etc
	wget -q https://testssl.sh/etc/Apple.pem -O $(PKG_PATH)/etc/Apple.pem
	wget -q https://testssl.sh/etc/Java.pem -O $(PKG_PATH)/etc/Java.pem
	wget -q https://testssl.sh/etc/Linux.pem -O $(PKG_PATH)/etc/Linux.pem
	wget -q https://testssl.sh/etc/Microsoft.pem -O $(PKG_PATH)/etc/Microsoft.pem
	wget -q https://testssl.sh/etc/Mozilla.pem -O $(PKG_PATH)/etc/Mozilla.pem
	wget -q https://testssl.sh/etc/ca_hashes.txt -O $(PKG_PATH)/etc/ca_hashes.txt
	wget -q https://testssl.sh/etc/cipher-mapping.txt -O $(PKG_PATH)/etc/cipher-mapping.txt
	wget -q https://testssl.sh/etc/client-simulation.txt -O $(PKG_PATH)/etc/client-simulation.txt
	wget -q https://testssl.sh/etc/client-simulation.wiresharked.txt -O $(PKG_PATH)/etc/client-simulation.wiresharked.txt
	wget -q https://testssl.sh/etc/common-primes.txt -O $(PKG_PATH)/etc/common-primes.txt
	wget -q https://testssl.sh/etc/curves.txt -O $(PKG_PATH)/etc/curves.txt
	wget -q https://testssl.sh/etc/tls_data.txt -O $(PKG_PATH)/etc/tls_data.txt
	zip -9rq $(PKG_PATH)/openssl.zip bin/openssl
	zip -9jrq $(PKG_PATH)/testssl.zip $(PKG_PATH)/etc
	zip -uj9q $(PKG_PATH)/testssl.zip $(PKG_PATH)/testssl $(PKG_PATH)/mapping-rfc.txt
	cp -rn $(PKG_PATH) workers/docker
	cp -rn $(PKG_PATH) web/docker
	rm -rf bin

package-upload: package
	$(CMD_AWS) s3 cp common/dist/trivialsec_common-$(COMMON_VERSION)-py2.py3-none-any.whl s3://trivialsec-assets/deploy-packages/trivialsec_common-$(COMMON_VERSION)-py2.py3-none-any.whl
	$(CMD_AWS) s3 cp $(PKG_PATH)/build.zip s3://trivialsec-assets/deploy-packages/build-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/openssl.zip s3://trivialsec-assets/deploy-packages/openssl-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/testssl.zip s3://trivialsec-assets/deploy-packages/testssl-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/web.zip s3://trivialsec-assets/deploy-packages/web-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/worker.zip s3://trivialsec-assets/deploy-packages/worker-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/sockets.zip s3://trivialsec-assets/deploy-packages/sockets-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp $(PKG_PATH)/amass_linux_amd64.zip s3://trivialsec-assets/deploy-packages/amass_linux_amd64-$(COMMON_VERSION).zip
	$(CMD_AWS) s3 cp web/docker/nginx.conf s3://trivialsec-assets/deploy-packages/nginx.conf

update-proxy:
	$(CMD_AWS) s3 cp assets/allowed-sites.txt s3://trivialsec-assets/deploy-packages/allowed-sites.txt
	$(CMD_AWS) s3 cp assets/squid.conf s3://trivialsec-assets/deploy-packages/squid.conf
