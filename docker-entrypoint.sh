#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 " +++ error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

_check_config() {
	toRun=( "$@" --verbose --help --log-bin-index="$(mktemp -u)" )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM

			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"

			$errors
		EOM
		exit 1
	fi
}

_datadir() {
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}

# TTL for etcd registries
[ -z "$TTL" ] && TTL=30

# galera wsrep cluster name required
if [ -z "$CLUSTER_NAME" ]; then
	echo >&2 ' +++ error:  You need to specify env CLUSTER_NAME'
	exit 1
fi

if [ "$1" = 'mysqld' ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"
	# Get config
	DATADIR="$(_datadir "$@")"

	if [ ! -d "$DATADIR/mysql" ]; then
		file_env 'MYSQL_ROOT_PASSWORD'
		# No random password or empty password
		if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
			echo >&2 ' +++ error: database is uninitialized and password options are not specified '
			echo >&2 ' +++  You need to specify both MYSQL_ROOT_PASSWORD and XTRABACKUP_PASSWORD'
			exit 1
		fi

		echo " +++ Creating and setting permissions to ${DATADIR}"
		mkdir -p "${DATADIR}"
		chown -R mysql:mysql "${DATADIR}"

		echo ' +++ Initializing database (mysql_install_db)'
		echo " +++  Datadir = ${DATADIR}"
		echo " +++  Running user = ${MYSQL_RUN_USER}"
		mysql_install_db --datadir="$DATADIR" --rpm --force --skip-name-resolve --user="$MYSQL_RUN_USER"
		echo ' +++ Database initialized (mysql_install_db)'

		"$@" --skip-networking --socket=/var/run/mysqld/mysqld.sock &
		pid="$!"

		echo ' +++ Testing first start after initialization...'
		mysql=( mysql --protocol=socket -uroot -hlocalhost --socket=/var/run/mysqld/mysqld.sock )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo ' +++ MySQL init process in progress...'
			sleep 1
		done

		if [ "$i" = 0 ]; then
			echo >&2 ' +++ MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		echo " +++ Creating root, xtrabackup and monitor users..."

		if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
			echo >&2 " +++ error: MYSQL_ROOT_PASSWORD not set!"
			echo >&2 "exiting ..."
			exit 1
		fi

		if [ -z "$XTRABACKUP_PASSWORD" ]; then
			echo >&2 " +++ error: XTRABACKUP_PASSWORD not set!"
			echo >&2 "exiting ..."
			exit 1
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
			GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
			GRANT REPLICATION CLIENT ON *.* TO monitor@'%' IDENTIFIED BY 'monitor';
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		echo ' +++ Users created...'
		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 ' +++ MySQL init process failed.'
			exit 1
		fi

		echo
		echo ' +++ MySQL init process done. Ready for start up.'
		echo
	fi
fi

function join { local IFS="$1"; shift; echo "$*"; }

if [ -z "$DISCOVERY_SERVICE" ]; then
	cluster_join=$CLUSTER_JOIN
else
	echo
	echo '>> Registering in the discovery service'

	etcd_hosts=$(echo $DISCOVERY_SERVICE | tr ',' ' ')
	flag=1

	echo
	# Loop to find a healthy etcd host
	for i in $etcd_hosts
	do
		echo ">> Connecting to http://$i"
		curl -s http://$i/health || continue
		if curl -s http://$i/health | jq -e 'contains({ "health": "true"})'; then
			healthy_etcd=$i
			flag=0
			break
		else
			echo >&2 ">> Node $i is unhealty. Proceed to the next node."
		fi
	done

	# Flag is 0 if there is a healthy etcd host
	if [ $flag -ne 0 ]; then
		echo ">> Couldn't reach healthy etcd nodes."
		exit 1
	fi

	echo
	echo ">> Selected healthy etcd: $healthy_etcd"

	if [ ! -z "$healthy_etcd" ]; then
		URL="http://$healthy_etcd/v2/keys/galera/$CLUSTER_NAME"

		set +e
		# Read the list of registered IP addresses
		echo >&2 ">> Retrieving list of keys for $CLUSTER_NAME"
		echo >&2 " >> $URL"
		sleep $[ ( $RANDOM % 5 )  + 1 ]s
		addr=$(curl -s $URL | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
		cluster_join=$(join , $addr)

		# Get ipaddres of container hostname
		ipaddr=$(hostname -i | tr -d ' ')
		[ -z $ipaddr ] && ipaddr=$(hostname -i | awk {'print $1'})

		echo
		if [ -z $cluster_join ]; then
			echo >&2 ">> Cluster address is empty. This is a the first node to come up."
			echo
			echo >&2 ">> Registering $ipaddr in http://$healthy_etcd"
			curl -s $URL/$ipaddr/ipaddress -X PUT -d "value=$ipaddr"
		else
			curl -s ${URL}?recursive=true\&sorted=true > /tmp/out
			running_nodes=$(cat /tmp/out | jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')
			echo
			echo ">> Running nodes: [${running_nodes}]"

			if [ -z "$running_nodes" ]; then
				# if there is no Synced node, determine the sequence number.
                                TMP=/tmp/wsrep-recover
                                echo >&2 ">> There is no node in synced state."
				echo >&2 ">> It's unsafe to bootstrap unless the sequence number is the latest."
                                echo >&2 ">> Determining the Galera last committed seqno.."
				echo
                                mysqld_safe --wsrep-recover 2>&1 | tee $TMP
                                seqno=$(cat $TMP | tr ' ' "\n" | grep -e '[a-z0-9]*-[a-z0-9]*:[0-9]' | head -1 | cut -d ":" -f 2)
				echo
                                if [ ! -z $seqno ]; then
                                        echo ">> Reporting seqno:$seqno to ${healthy_etcd}."
                                        WAIT=$(($TTL * 2))
                                        curl -s $URL/$ipaddr/seqno -X PUT -d "value=$seqno&ttl=$WAIT"
                                else
                                        echo ">> Unable to determine Galera sequence number."
                                        exit 1
                                fi
                                rm $TMP

                                echo
                                echo ">> Sleeping for $TTL seconds to wait for other nodes to report."
                                sleep $TTL

                                echo
                                echo >&2 ">> Retrieving list of seqno for $CLUSTER_NAME"
                                bootstrap_flag=1

				# Retrieve seqno from etcd
				curl -s ${URL}?recursive=true\&sorted=true > /tmp/out
				cluster_seqno=$(cat /tmp/out | jq -r '.node.nodes[].nodes[]? | select(.key | contains ("seqno")) | .value' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

                                for i in $cluster_seqno; do
                                        if [ $i -gt $seqno ]; then
                                                bootstrap_flag=0
                                                echo >&2 ">> Found another node holding a greater seqno ($i/$seqno)"
                                        fi
                                done

				echo
                                if [ $bootstrap_flag -eq 1 ]; then
					# Find the earliest node to report if there is no higher seqno
					node_to_bootstrap=$(cat /tmp/out | jq -c '.node.nodes[].nodes[]?' | grep seqno | tr ',:\"' ' ' | sort -k 11 | head -1 | awk -F'/' '{print $(NF-1)}')
					if [ "$node_to_bootstrap" == "$ipaddr" ]; then
	                                        echo >&2 ">> This node is safe to bootstrap."
						cluster_join=
					else
						echo >&2 ">> Based on timestamp, $node_to_bootstrap is the chosen node to bootstrap."
						echo >&2 ">> Wait again for $TTL seconds to look for a bootstrapped node."
                                        	sleep $TTL
	                                        curl -s ${URL}?recursive=true\&sorted=true > /tmp/out

						# Look for a synced node again
        	                                running_nodes2=$(cat /tmp/out | jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

                	                        echo
                        	                echo ">> Running nodes: [${running_nodes2}]"

        	                                if [ ! -z "$running_nodes2" ]; then
                	                                cluster_join=$(join , $running_nodes2)
                        	                else
                                	                echo
                                        	        echo >&2 ">> Unable to find a bootstrapped node to join."
                                                	echo >&2 ">> Exiting."
	                                                exit 1
        	                                fi

					fi
                                else
                                        echo >&2 ">> Refusing to start for now because there is a node holding higher seqno."
                                        echo >&2 ">> Wait again for $TTL seconds to look for a bootstrapped node."
                                        sleep $TTL

					# Look for a synced node again
					curl -s ${URL}?recursive=true\&sorted=true > /tmp/out
					running_nodes3=$(cat /tmp/out | jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

					echo
					echo ">> Running nodes: [${running_nodes3}]"

					if [ ! -z "$running_nodes2" ]; then
						cluster_join=$(join , $running_nodes3)
					else
						echo
						echo >&2 ">> Unable to find a bootstrapped node to join."
						echo >&2 ">> Exiting."
						exit 1
					fi
                                fi
			else
				# if there is a Synced node, join the address
				cluster_join=$(join , $running_nodes)
			fi

		fi
		set -e

		echo
		echo >&2 ">> Cluster address is gcomm://$cluster_join"
	else
		echo
		echo >&2 '>> No healthy etcd host detected. Refused to start.'
		exit 1
	fi
fi

echo
echo ">> Starting reporting script in the background"
nohup /report_status.sh root $MYSQL_ROOT_PASSWORD $CLUSTER_NAME $TTL $DISCOVERY_SERVICE &

# set IP address based on the primary interface
sed -i "s|WSREP_NODE_ADDRESS|$ipaddr|g" /etc/mysql/conf.d/galera.cnf
sed -i "s|WSREP_CLUSTER_NAME|$CLUSTER_NAME|g" /etc/mysql/conf.d/galera.cnf

echo
#echo ">> Starting mysqld process"
mysqld --user=mysql --wsrep_cluster_name=$CLUSTER_NAME --wsrep_cluster_address="gcomm://$cluster_join" --wsrep_sst_method=xtrabackup-v2 --wsrep_sst_auth="xtrabackup:$XTRABACKUP_PASSWORD" --log-error=${DATADIR}error.log $CMDARG

#echo ' +++ Starting up...'
#exec "$@"
