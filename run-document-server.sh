#!/bin/bash

APP_DIR="/var/www/onlyoffice/documentserver"
DATA_DIR="/var/www/onlyoffice/Data"
LOG_DIR="/var/log/onlyoffice/documentserver"

ONLYOFFICE_DATA_CONTAINER=${ONLYOFFICE_DATA_CONTAINER:-false}
ONLYOFFICE_DATA_CONTAINER_HOST=${ONLYOFFICE_DATA_CONTAINER_HOST:-localhost}
ONLYOFFICE_DATA_CONTAINER_PORT=80

SSL_CERTIFICATES_DIR="${DATA_DIR}/certs"
SSL_CERTIFICATE_PATH=${SSL_CERTIFICATE_PATH:-${SSL_CERTIFICATES_DIR}/onlyoffice.crt}
SSL_KEY_PATH=${SSL_KEY_PATH:-${SSL_CERTIFICATES_DIR}/onlyoffice.key}
CA_CERTIFICATES_PATH=${CA_CERTIFICATES_PATH:-${SSL_CERTIFICATES_DIR}/ca-certificates.pem}
SSL_DHPARAM_PATH=${SSL_DHPARAM_PATH:-${SSL_CERTIFICATES_DIR}/dhparam.pem}
SSL_VERIFY_CLIENT=${SSL_VERIFY_CLIENT:-off}
ONLYOFFICE_HTTPS_HSTS_ENABLED=${ONLYOFFICE_HTTPS_HSTS_ENABLED:-true}
ONLYOFFICE_HTTPS_HSTS_MAXAGE=${ONLYOFFICE_HTTPS_HSTS_MAXAG:-31536000}
SYSCONF_TEMPLATES_DIR="/app/onlyoffice/setup/config"

NGINX_CONFD_PATH="/etc/nginx/conf.d";
NGINX_ONLYOFFICE_PATH="${NGINX_CONFD_PATH}/onlyoffice-documentserver.conf";
NGINX_ONLYOFFICE_INCLUDES_PATH="/etc/nginx/includes";
NGINX_ONLYOFFICE_EXAMPLE_PATH=${NGINX_ONLYOFFICE_INCLUDES_PATH}/onlyoffice-documentserver-example.conf

NGINX_CONFIG_PATH="/etc/nginx/nginx.conf"
NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-$(grep processor /proc/cpuinfo | wc -l)}
NGINX_WORKER_CONNECTIONS=${NGINX_WORKER_CONNECTIONS:-$(ulimit -n)}

ONLYOFFICE_DEFAULT_CONFIG=/etc/onlyoffice/documentserver/default.json

JSON="json -q -f ${ONLYOFFICE_DEFAULT_CONFIG}"

LOCAL_SERVICES=()

read_setting(){
  POSTGRESQL_SERVER_HOST=${POSTGRESQL_SERVER_HOST:-$(${JSON} services.CoAuthoring.sql.dbHost)}
  POSTGRESQL_SERVER_PORT=${POSTGRESQL_SERVER_PORT:-$(${JSON} services.CoAuthoring.sql.dbPort)}
  POSTGRESQL_SERVER_DB_NAME=${POSTGRESQL_SERVER_DB_NAME:-$(${JSON} services.CoAuthoring.sql.dbName)}
  POSTGRESQL_SERVER_USER=${POSTGRESQL_SERVER_USER:-$(${JSON} services.CoAuthoring.sql.dbUser)}
  POSTGRESQL_SERVER_PASS=${POSTGRESQL_SERVER_PASS:-$(${JSON} services.CoAuthoring.sql.dbPass)}

  RABBITMQ_SERVER_URL=${RABBITMQ_SERVER_URL:-$(${JSON} rabbitmq.url)}
  parse_rabbitmq_url

  REDIS_SERVER_HOST=${REDIS_SERVER_HOST:-$(${JSON} services.CoAuthoring.redis.host)}
  REDIS_SERVER_PORT=${REDIS_SERVER_PORT:-$(${JSON} services.CoAuthoring.redis.port)}
}

parse_rabbitmq_url(){
  local amqp=${RABBITMQ_SERVER_URL}

  # extract the protocol
  local proto="$(echo $amqp | grep :// | sed -e's,^\(.*://\).*,\1,g')"
  # remove the protocol
  local url="$(echo ${amqp/$proto/})"

  # extract the user and password (if any)
  local userpass="`echo $url | grep @ | cut -d@ -f1`"
  local pass=`echo $userpass | grep : | cut -d: -f2`

  local user
  if [ -n "$pass" ]; then
    user=`echo $userpass | grep : | cut -d: -f1`
  else
    user=$userpass
  fi
  echo $user

  # extract the host
  local hostport="$(echo ${url/$userpass@/} | cut -d/ -f1)"
  # by request - try to extract the port
  local port="$(echo $hostport | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"

  local host
  if [ -n "$port" ]; then
    host=`echo $hostport | grep : | cut -d: -f1`
  else
    host=$hostport
    port="5672"
  fi

  # extract the path (if any)
  local path="$(echo $url | grep / | cut -d/ -f2-)"

  RABBITMQ_SERVER_HOST=$host
  RABBITMQ_SERVER_USER=$user
  RABBITMQ_SERVER_PASS=$pass
  RABBITMQ_SERVER_PORT=$port
}

waiting_for_connection(){
  until nc -z -w 3 "$1" "$2"; do
    >&2 echo "Waiting for connection to the $1 host on port $2"
    sleep 1
  done
}

waiting_for_postgresql(){
  waiting_for_connection ${POSTGRESQL_SERVER_HOST} ${POSTGRESQL_SERVER_PORT}
}

waiting_for_rabbitmq(){
  waiting_for_connection ${RABBITMQ_SERVER_HOST} ${RABBITMQ_SERVER_PORT}
}

waiting_for_redis(){
  waiting_for_connection ${REDIS_SERVER_HOST} ${REDIS_SERVER_PORT}
}
waiting_for_datacontainer(){
  waiting_for_connection ${ONLYOFFICE_DATA_CONTAINER_HOST} ${ONLYOFFICE_DATA_CONTAINER_PORT}
}
update_postgresql_settings(){
  ${JSON} -I -e "this.services.CoAuthoring.sql.dbHost = '${POSTGRESQL_SERVER_HOST}'"
  ${JSON} -I -e "this.services.CoAuthoring.sql.dbPort = '${POSTGRESQL_SERVER_PORT}'"
  ${JSON} -I -e "this.services.CoAuthoring.sql.dbName = '${POSTGRESQL_SERVER_DB_NAME}'"
  ${JSON} -I -e "this.services.CoAuthoring.sql.dbUser = '${POSTGRESQL_SERVER_USER}'"
  ${JSON} -I -e "this.services.CoAuthoring.sql.dbPass = '${POSTGRESQL_SERVER_PASS}'"
}

update_rabbitmq_setting(){
  ${JSON} -I -e "this.rabbitmq.url = '${RABBITMQ_SERVER_URL}'"
}

update_redis_settings(){
  ${JSON} -I -e "this.services.CoAuthoring.redis.host = '${REDIS_SERVER_HOST}'"
  ${JSON} -I -e "this.services.CoAuthoring.redis.port = '${REDIS_SERVER_PORT}'"
}

create_postgresql_db(){
  CONNECTION_PARAMS="-h${POSTGRESQL_SERVER_HOST} -U${POSTGRESQL_SERVER_USER} -w"
  if [ -n "${POSTGRESQL_SERVER_PASS}" ]; then
    export PGPASSWORD=${POSTGRESQL_SERVER_PASS}
  fi

  PSQL="psql -q $CONNECTION_PARAMS"
  CREATEDB="createdb $CONNECTION_PARAMS"

  # Create db on remote server
  if $PSQL -lt | cut -d\| -f 1 | grep -qw | grep 0; then
    $CREATEDB $DB_NAME
  fi

  $PSQL -d "${POSTGRESQL_SERVER_DB_NAME}" -f "${APP_DIR}/server/schema/postgresql/createdb.sql"
}

update_nginx_settings(){
  # Set up nginx
  sed 's/^worker_processes.*/'"worker_processes ${NGINX_WORKER_PROCESSES};"'/' -i ${NGINX_CONFIG_PATH}
  sed 's/worker_connections.*/'"worker_connections ${NGINX_WORKER_CONNECTIONS};"'/' -i ${NGINX_CONFIG_PATH}
  sed 's/access_log.*/'"access_log off;"'/' -i ${NGINX_CONFIG_PATH}

  # setup HTTPS
  if [ -f "${SSL_CERTIFICATE_PATH}" -a -f "${SSL_KEY_PATH}" ]; then
    cp ${NGINX_CONFD_PATH}/onlyoffice-documentserver-ssl.conf.template ${NGINX_ONLYOFFICE_PATH}

    # configure nginx
    sed 's,{{SSL_CERTIFICATE_PATH}},'"${SSL_CERTIFICATE_PATH}"',' -i ${NGINX_ONLYOFFICE_PATH}
    sed 's,{{SSL_KEY_PATH}},'"${SSL_KEY_PATH}"',' -i ${NGINX_ONLYOFFICE_PATH}

    # if dhparam path is valid, add to the config, otherwise remove the option
    if [ -r "${SSL_DHPARAM_PATH}" ]; then
      sed 's,{{SSL_DHPARAM_PATH}},'"${SSL_DHPARAM_PATH}"',' -i ${NGINX_ONLYOFFICE_PATH}
    else
      sed '/ssl_dhparam {{SSL_DHPARAM_PATH}};/d' -i ${NGINX_ONLYOFFICE_PATH}
    fi

    sed 's,{{SSL_VERIFY_CLIENT}},'"${SSL_VERIFY_CLIENT}"',' -i ${NGINX_ONLYOFFICE_PATH}

    if [ -f "${CA_CERTIFICATES_PATH}" ]; then
      sed 's,{{CA_CERTIFICATES_PATH}},'"${CA_CERTIFICATES_PATH}"',' -i ${NGINX_ONLYOFFICE_PATH}
    else
      sed '/{{CA_CERTIFICATES_PATH}}/d' -i ${NGINX_ONLYOFFICE_PATH}
    fi

    if [ "${ONLYOFFICE_HTTPS_HSTS_ENABLED}" == "true" ]; then
      sed 's/{{ONLYOFFICE_HTTPS_HSTS_MAXAGE}}/'"${ONLYOFFICE_HTTPS_HSTS_MAXAGE}"'/' -i ${NGINX_ONLYOFFICE_PATH}
    else
      sed '/{{ONLYOFFICE_HTTPS_HSTS_MAXAGE}}/d' -i ${NGINX_ONLYOFFICE_PATH}
    fi
  else
    cp ${NGINX_CONFD_PATH}/onlyoffice-documentserver.conf.template ${NGINX_ONLYOFFICE_PATH}
  fi
  
  if [ -f "${NGINX_ONLYOFFICE_EXAMPLE_PATH}" ]; then
    sed 's/linux/docker/' -i ${NGINX_ONLYOFFICE_EXAMPLE_PATH}
  fi
}

update_supervisor_settings(){
  # Copy modified supervisor start script
  cp ${SYSCONF_TEMPLATES_DIR}/supervisor/supervisor /etc/init.d/
  # Copy modified supervisor config
  cp ${SYSCONF_TEMPLATES_DIR}/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
}

# create base folders
for i in converter docservice spellchecker metrics gc; do
  mkdir -p "${LOG_DIR}/$i"
done

mkdir -p ${LOG_DIR}-example

if [ ${ONLYOFFICE_DATA_CONTAINER_HOST} = "localhost" ]; then

  read_setting

  # update settings by env variables
  if [ ${POSTGRESQL_SERVER_HOST} != "localhost" ]; then
    update_postgresql_settings
    waiting_for_postgresql
    create_postgresql_db
  else
    LOCAL_SERVICES+=("postgresql")
  fi

  if [ ${RABBITMQ_SERVER_HOST} != "localhost" ]; then
    update_rabbitmq_setting
  else
    LOCAL_SERVICES+=("redis-server")
  fi

  if [ ${REDIS_SERVER_HOST} != "localhost" ]; then
    update_redis_settings
  else
    LOCAL_SERVICES+=("rabbitmq-server")
  fi
else
  # no need to update settings just wait for remote data
  waiting_for_datacontainer

  # read settings after the data container in ready state
  # to prevent get unconfigureted data
  read_setting
fi

#start needed local services
for i in ${LOCAL_SERVICES[@]}; do
  service $i start
done

if [ ${ONLYOFFICE_DATA_CONTAINER} != "true" ]; then
  waiting_for_postgresql
  waiting_for_rabbitmq
  waiting_for_redis

  update_nginx_settings

  update_supervisor_settings
  service supervisor start
fi

# nginx used as a proxy, and as data container status service.
# it run in all cases.
service nginx start

# Regenerate the fonts list and the fonts thumbnails
documentserver-generate-allfonts.sh ${ONLYOFFICE_DATA_CONTAINER}

while true
do
	echo "running"
	sleep 5
done
