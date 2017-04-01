#!/bin/bash
echo '*** Running my_init mariadb.sh'
echo " *** Env MYSQL_RUN_USER = ${MYSQL_RUN_USER}"
echo " *** Env MYSQL_ROOT_PASSWORD = ${MYSQL_ROOT_PASSWORD}"
echo " *** Env XTRABACKUP_PASSWORD = ${XTRABACKUP_PASSWORD}"
echo " *** Env MYSQL_INITDB_SKIP_TZINFO = ${MYSQL_INITDB_SKIP_TZINFO}"
echo " *** Env CLUSTER_NAME = ${CLUSTER_NAME}"

# Execute in foreground, don't fork it!
echo "*** Starting MariaDB ${MARIADB_VERSION}"

# First arg of docker-entrypoint.sh and nothing else
exec /sbin/setuser $MYSQL_RUN_USER /bin/bash /docker-entrypoint.sh mysqld >> /var/log/mysql/mariadb.log 2>&1
