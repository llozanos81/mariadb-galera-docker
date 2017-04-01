# vim:set ft=dockerfile:
# Phusion Dcoker baseimage based on ubuntu:16.04
# MAINTAINER Phusion <info@phusion.nl>
FROM phusion/baseimage:0.9.19

# Dockerfile based on Docker official mariadb:10.1 modified to run on phusion/baseimage and fewer layers
# https://github.com/docker-library/mariadb/blob/58422728079b38cfd883d11fa1ec0252fa6779fe/10.1/Dockerfile
MAINTAINER Luis R. Lozano <luisrlozano@gmail.com>

# mariaDB 10.1 version for Xenial
# add updated (March 20th, 2017) Key fingerprints for percona and mariadb repositories
ENV MARIADB_MAJOR=10.1 MYSQL_RUN_USER=mysql MARIADB_VERSION=10.1.22+maria-1~xenial GPG_KEYS=" \
# pub   4096R/8507EFA5 2016-06-30
#       Key fingerprint = 4D1B B29D 63D9 8E42 2B21  13B1 9334 A25F 8507 EFA5
# uid                  Percona MySQL Development Team (Packaging key) <mysql-dev@percona.com>
# sub   4096R/4CAC6D72 2016-06-30
	4D1BB29D63D98E422B2113B19334A25F8507EFA5 \
# pub   4096R/C74CD1D8 2016-03-30
#       Key fingerprint = 177F 4010 FE56 CA33 3630  0305 F165 6F24 C74C D1D8
# uid                  MariaDB Signing Key <signing-key@mariadb.org>
# sub   4096R/DE8F6914 2016-03-30
        177F4010FE56CA3336300305F1656F24C74CD1D8"

RUN set -x \
# add our user (MYSQL_RUN_USER) and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
	&& groupadd -r mysql && useradd -r -g mysql mysql \
	&& mkdir /docker-entrypoint-initdb.d \
# install "apt-transport-https" for Percona's repo (switched to https-only)
# install curl and jq requiered by etcd discover and registry services
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		apt-transport-https ca-certificates curl jq \
	&& rm -rf /var/lib/apt/lists/* \
# importing Keys in $GPG_KEYS
	&& set -ex; \
	export GNUPGHOME="$(mktemp -d)"; \
	for key in $GPG_KEYS; do \
		gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	done; \
	gpg --export $GPG_KEYS > /etc/apt/trusted.gpg.d/mariadb.gpg; \
	rm -r "$GNUPGHOME"; \
	apt-key list \
# creating repositories for Percona and MariaDB
	&& echo "deb https://repo.percona.com/apt xenial main" > /etc/apt/sources.list.d/percona.list \
	&& { \
		echo 'Package: *'; \
		echo 'Pin: release o=Percona Development Team'; \
		echo 'Pin-Priority: 998'; \
	} > /etc/apt/preferences.d/percona \
# OSU Open Source Lab mirror
	&& echo "deb http://ftp.osuosl.org/pub/mariadb/repo/$MARIADB_MAJOR/ubuntu xenial main" > /etc/apt/sources.list.d/mariadb.list \
	&& { \
		echo 'Package: *'; \
		echo 'Pin: release o=MariaDB'; \
		echo 'Pin-Priority: 999'; \
	} > /etc/apt/preferences.d/mariadb \
# add repository pinning to make sure dependencies from this MariaDB repo are preferred over Debian dependencies
#  libmariadbclient18 : Depends: libmysqlclient18 (= 5.5.42+maria-1~wheezy) but 5.5.43-0+deb7u1 is to be installed

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
	&& { \
		echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password password 'unused'; \
		echo mariadb-server-$MARIADB_MAJOR mysql-server/root_password_again password 'unused'; \
	} | debconf-set-selections \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		mariadb-server=$MARIADB_VERSION \
# percona-xtrabackup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
		percona-xtrabackup \
		socat \
	&& rm -rf /var/lib/apt/lists/* \
# comment out any "user" entires in the MySQL config ("docker-entrypoint.sh" or "--user" will handle user switching)
	&& sed -ri 's/^user\s/#&/' /etc/mysql/my.cnf /etc/mysql/conf.d/* \
# purge and re-create /var/lib/mysql with appropriate ownership
	&& rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
	&& chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	&& chmod 777 /var/run/mysqld \
# comment out a few problematic configuration values
# don't reverse lookup hostnames, they are usually another container
	&& sed -Ei 's/^(bind-address|log)/#&/' /etc/mysql/my.cnf \
	&& echo 'skip-host-cache\nskip-name-resolve' | awk '{ print } $1 == "[mysqld]" && c == 0 { c = 1; system("cat") }' /etc/mysql/my.cnf > /tmp/my.cnf \
        && mkdir /etc/service/mariadb \
	&& mv /tmp/my.cnf /etc/mysql/my.cnf \
# O_DSYNC to use inside container
        && { \
                echo '[mysqld]'; \
                echo 'innodb_flush_method=O_DSYNC'; \
        } > /etc/mysql/conf.d/innodb_flush_O_DSYNC.cnf \
# Bind to 0.0.0.0
        && { \
                echo '[mysqld]'; \
                echo 'bind_address = 0.0.0.0'; \
        } > /etc/mysql/conf.d/bind_address.cnf \
# Galera options
        && { \
                echo '[galera]'; \
                echo 'binlog_format=ROW'; \
		echo 'innodb_flush_log_at_trx_commit=0'; \
		echo 'innodb_autoinc_lock_mode=2'; \
		echo 'wsrep_slave_threads=2'; \
		echo 'wsrep_cluster_address=gcomm://'; \
		echo 'wsrep_sst_method=xtrabackup-v2'; \
		echo 'wsrep_sst_auth="root:"'; \
		echo 'wsrep_node_address=WSREP_NODE_ADDRESS'; \
		echo 'wsrep_cluster_name=WSREP_CLUSTER_NAME'; \
        } > /etc/mysql/conf.d/galera.cnf

# Ephemeral Storage, keep always a running copy
#VOLUME /var/lib/mysql

COPY docker-entrypoint.sh report_status.sh /usr/local/bin/
# Using default entrypoint
# adding mariadb service for my_init
ADD mariadb.sh /etc/service/mariadb/run
RUN set -x \
        && ln -s /usr/local/bin/docker-entrypoint.sh / \
        && chmod +x /usr/local/bin/docker-entrypoint.sh \
        && ln -s /usr/local/bin/report_status.sh / \
        && chmod +x /usr/local/bin/report_status.sh \
	&& apt-get -y upgrade \
        && apt-get -y autoclean \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Exposing mysql and galera services ports
EXPOSE 3306 4567 4568

CMD ["/sbin/my_init"]

