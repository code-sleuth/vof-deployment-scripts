#!/bin/bash

set -ex
set -o pipefail

export SCRIPT_FILE="/home/vof/setup-scripts"

# import functions
. ${SCRIPT_FILE}/setup_filebeat.sh
. ${SCRIPT_FILE}/setup_metricbeat.sh

get_var() {
  local name="$1"

  curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${name}"
}

export PORT="${PORT:-8080}"
export SSL_CONFIG_PATH="ssl://0.0.0.0:8080?key=/home/vof/andela_key.key&cert=/home/vof/andela_certificate.crt"
export RAILS_ENV="$(get_var "railsEnv")"
export REDIS_IP=$(get_var "redisIp")
export BUGSNAG_KEY="$(get_var "bugsnagKey")"
export DEPLOY_ENV="$(get_var "railsEnv")"
if [[ "$(get_var "railsEnv")" == "design-v2" ]]; then
 export DEPLOY_ENV="staging"
fi

export BUCKET_NAME=$(get_var "bucketName")
sudo echo "export SLACK_WEBHOOK=$(get_var "slackWebhook")" >> /home/vof/.env_setup_rc
sudo echo "export SLACK_CHANNEL=$(get_var "slackChannel")" >> /home/vof/.env_setup_rc
gsutil cp gs://${BUCKET_NAME}/ssl/andela_key.key /home/vof/andela_key.key
gsutil cp gs://${BUCKET_NAME}/ssl/andela_certificate.crt /home/vof/andela_certificate.crt


export API_URL='https://api-staging.andela.com/'
export LOGIN_URL='https://api-staging.andela.com/login?redirect_url='
export LOGOUT_URL='https://api-staging.andela.com/logout?redirect_url='

if [ "$DEPLOY_ENV" == "production" ]; then
  export API_URL='https://api-prod.andela.com/'
  export LOGIN_URL='https://api-prod.andela.com/login?redirect_url='
  export LOGOUT_URL='https://api-prod.andela.com/logout?redirect_url='
fi

update_application_yml() {
  cat <<EOF >> /home/vof/app/config/application.yml
ACTION_CABLE_URL: '$(get_var "cableURL")'
REDIS_URL: 'redis://${REDIS_IP}'
BUGSNAG_KEY: '$(get_var "bugsnagKey")'
DB_NAME: '$(get_var "databaseInstanceName")'
API_URL: '${API_URL}'
LOGIN_URL: '${LOGIN_URL}'
LOGOUT_URL: '${LOGOUT_URL}'
USER_MICROSERVICE_API_URL: '$(get_var "userMicroserviceApiUrl")'
USER_MICROSERVICE_API_TOKEN: '$(get_var "userMicroserviceApiToken")'
POSTGRES_USER: '$(get_var "databaseUser")'
POSTGRES_PASSWORD: '$(get_var "databasePassword")'
POSTGRES_HOST: '$(get_var "databaseHost")'
POSTGRES_DB: '$(get_var "databaseName")'
GOOGLE_STORAGE_ACCESS_KEY_ID: '$(get_var "google_storage_access_key_id")'
GOOGLE_STORAGE_SECRET_ACCESS_KEY: '$(get_var "google_storage_secret_access_key")'
EOF
}

create_secrets_yml() {
  cat <<EOF > /home/vof/app/config/secrets.yml
production:
  secret_key_base: "$(openssl rand -hex 64)"
staging:
  secret_key_base: "$(openssl rand -hex 64)"
development:
  secret_key_base: "$(openssl rand -hex 64)"
sandbox:
  secret_key_base: "$(openssl rand -hex 64)"
EOF
}

create_log_files() {
  mkdir -p /var/log/vof
  touch /var/log/vof/vof.out.log /var/log/vof/vof.err.log
  sudo chown -R vof:vof /var/log/vof/vof.out.log /var/log/vof/vof.err.log
}

create_vof_supervisord_conf() {
  sudo cat <<EOF > /etc/supervisor/conf.d/vof.conf
[program:vof]
command=/usr/bin/env RAILS_ENV=${DEPLOY_ENV} PORT=${PORT} RAILS_SERVE_STATIC_FILES=true /usr/bin/nohup /usr/local/bin/bundle exec puma -b ${SSL_CONFIG_PATH} -C config/puma.rb
directory=/home/vof/app
autostart=true
autorestart=true
startretries=3
stderr_logfile=/var/log/vof/vof.err.log
stdout_logfile=/var/log/vof/vof.out.log
user=vof
EOF
}
authenticate_service_account() {
  if gcloud auth activate-service-account --key-file=/home/vof/account.json; then
    echo "Service account authentication successful"
  fi
}

authorize_database_access_networks() {
  CURRENTIPS="$(gcloud compute instances list --project vof-tracker-app | grep ${RAILS_ENV}-vof-app-instance | awk -v ORS=, '{if ($5) print $5}' | sed 's/,$//')"

  # authorize certain IPs to access staging db but not the production db
  if [ "$RAILS_ENV" != "production" ]; then
    CURRENTIPS="${CURRENTIPS},105.21.72.66,105.21.32.90,105.27.99.66,41.90.97.134,41.75.89.154,169.239.188.10,41.215.245.118"
  fi

  # ensure replica's authorized networks are also updated
  for sqlInstanceName in $(gcloud sql instances list --project vof-tracker-app | grep ${RAILS_ENV}-vof-database-instance | awk -v ORS=" " '{if ($1 !~ /production-vof-database-instance-vew0wndaum8/) print $1}'); do
    gcloud sql instances patch $sqlInstanceName --quiet --authorized-networks=$CURRENTIPS,41.75.89.154,158.106.201.190,41.215.245.162,108.41.204.165,14.140.245.142,182.74.31.70,54.208.19.24,35.166.153.63,54.208.19.13,54.69.5.5,52.36.120.247,52.45.79.49,34.199.147.194
  done 

}

authorize_redis_access_ips() {
  CURRENTIPS="$(gcloud compute instances list --project vof-tracker-app | grep ${RAILS_ENV}-vof-app-instance | awk -v ORS=, '{if ($5) print $5}' | sed 's/,$//')"
  gcloud compute firewall-rules update vof-${RAILS_ENV}-redis-firewall --source-ranges=${CURRENTIPS}
}

get_database_dump_file() {
  if [[ "$RAILS_ENV" == "production" || "$RAILS_ENV" == "staging" || "$RAILS_ENV" == "sandbox" ]]; then
    if gsutil cp gs://${BUCKET_NAME}/database-backups/vof_${RAILS_ENV}.sql /home/vof/vof_${RAILS_ENV}.sql; then
      echo "Database dump file created succesfully"
    fi
  fi
}
start_bugsnag(){
 local app_root="/home/vof/app"
sudo -u vof bash -c " cd ${app_root} && rails generate bugsnag ${BUGSNAG_KEY} -f"
}

start_app() {
  local app_root="/home/vof/app"

  sudo -u vof bash -c "mkdir -p /home/vof/app/log"

  if [[ "$RAILS_ENV" == "production" || "$RAILS_ENV" == "staging" || "$RAILS_ENV" == "sandbox" ]]; then
    # One time actions
    # Check if the database was already imported
    if export PGPASSWORD=$(get_var "databasePassword"); psql -h $(get_var "databaseHost") -p 5432 -U $(get_var "databaseUser") -d $(get_var "databaseName") -c 'SELECT key FROM ar_internal_metadata' 2>/dev/null | grep environment >/dev/null; then
      sudo -u vof bash -c "cd ${app_root} && env RAILS_ENV=${RAILS_ENV} rails db:migrate"
      sudo -u vof bash -c "cd ${app_root} rails db:seed"
    else
      # Import database dump.
      sudo -u postgres bash -c "export PGPASSWORD=$(get_var "databasePassword"); psql -h  $(get_var "databaseHost") -p 5432 -U $(get_var "databaseUser") -d $(get_var "databaseName") < /home/vof/vof_${RAILS_ENV}.sql"
    fi
  else
    sudo -u vof bash -c "cd ${app_root} && env RAILS_ENV=${RAILS_ENV} rails db:setup"
    sudo -u vof bash -c "cd ${app_root} && env RAILS_ENV=${RAILS_ENV} rails db:seed"
  fi
  supervisorctl update && supervisorctl reload
}

# this configures the application logging by google-fluentd to send application logs to
# the google logging web UI just like all other logs like syslog and VM logs. For indepth explanation on how this is done and why everything is where it is
# check out the logging documentation on this application's repo.
configure_google_fluentd_logging() {

  sudo cat <<EOF > /etc/google-fluentd/config.d/vof_development_logs.conf
<source>
  @type tail
  format none
  path /home/vof/app/log/development.log
  pos_file /var/lib/google-fluentd/pos/vof.pos
  read_from_head true
  tag vof_development_logs
</source>
EOF

  sudo cat <<EOF > /etc/google-fluentd/config.d/vof_sandbox_logs.conf
<source>
  @type tail
  format none
  path /home/vof/app/log/sandbox.log
  pos_file /var/lib/google-fluentd/pos/vof.pos
  read_from_head true
  tag vof_sandbox_logs
</source>
EOF

  sudo cat <<EOF > /etc/google-fluentd/config.d/vof_production_logs.conf
<source>
  @type tail
  format none
  path /home/vof/app/log/production.log
  pos_file /var/lib/google-fluentd/pos/vof.pos
  read_from_head true
  tag vof_production_logs
</source>
EOF

  sudo cat <<EOF > /etc/google-fluentd/config.d/vof_production_test_logs.conf
<source>
  @type tail
  format none
  path /home/vof/app/log/production_test.log
  pos_file /var/lib/google-fluentd/pos/vof.pos
  read_from_head true
  tag vof_production_test_logs
</source>
EOF

  sudo cat <<EOF > /etc/google-fluentd/config.d/vof_staging_logs.conf
<source>
  @type tail
  format none
  path /home/vof/app/log/staging.log
  pos_file /var/lib/google-fluentd/pos/vof.pos
  read_from_head true
  tag vof_staging_logs
</source>
EOF

}

# This configures the file responsible for tracking the last read position of the logs
# by google-fluentd.
configure_log_reader_positioning(){
  sudo cat <<EOF > /var/lib/google-fluentd/pos/vof.pos
/home/vof/app/log/production.log   000000000000000  000000000000000
/home/vof/app/log/staging.log   000000000000000  000000000000000
/home/vof/app/log/production_test.log  000000000000000  000000000000000
/home/vof/app/log/development.log  000000000000000  000000000000000
/home/vof/app/log/sandbox.log  000000000000000  000000000000000
EOF
}

# this right here restarts the google fluentd service so that the above changes can take effect.
restart_google_fuentd(){
  sudo service google-fluentd restart
}

configure_logrotate() {
# Configure logrotate.
  cat <<EOF > /etc/logrotate.conf
su root root
include /etc/logrotate.d
/var/log/vof/vof.out.log
/var/log/vof/vof.err.log
/home/vof/app/log/staging.log
/home/vof/app/log/sandbox.log
/home/vof/app/log/production.log
{
    weekly
    size 250M
    rotate 4
    create 0664 vof vof
    missingok
    notifempty
}
/var/log/wtmp {
    missingok
    monthly
    create 0664 root utmp
    rotate 1
}
/var/log/btmp {
    missingok
    monthly
    create 0660 root utmp
    rotate 1
}
EOF

# Create a cronjob to send slack notifications after running logrotate.
  cat > log_cron <<'EOF'
0 9 * * 5 /bin/bash -lc 'source /home/vof/.env_setup_rc; curl -X POST --data-urlencode "payload={\"channel\": \"$(echo $SLACK_CHANNEL)\", \"username\": \"Logrotate\", \"text\": \"*Logs successfully rotated in $(uname -n)*\n>>>$(sudo /usr/sbin/logrotate /etc/logrotate.conf --state --force)\", \"icon_emoji\": \":sparkle:\"}" $(echo $SLACK_WEBHOOK)'
EOF
}

create_unattended_upgrades_cronjob() {
  cat > upgrades_cron <<'EOF'
0 9 * * 5 /bin/bash -lc 'source /home/vof/.env_setup_rc; curl -X POST --data-urlencode "payload={\"channel\": \"$(echo $SLACK_CHANNEL)\", \"username\": \"unattended-upgrades\", \"text\": \"*Unattended upgrades report from $(uname -n)*\n>>>$(sudo unattended-upgrade -v)\", \"icon_emoji\": \":bell:\"}" $(echo $SLACK_WEBHOOK)'
EOF

}

# Reason: When the logs are successfully rotated, the newly setup log files can't be written by the current rails app
# instance so supervisord is reload through this cron so that the app starts writing the log to the new log file.
create_supervisord_cronjob() {
  cat > supervisord_cron <<'EOF'
1 9 * * * supervisorctl update && supervisorctl reload
EOF
}

update_crontab() {
  cat upgrades_cron log_cron supervisord_cron | crontab
  rm upgrades_cron log_cron supervisord_cron
}

main() {
  echo "startup script invoked at $(date)" >> /tmp/script.log

  create_log_files
  update_application_yml
  create_secrets_yml
  create_vof_supervisord_conf
  authenticate_service_account
  set +o errexit
  set +o pipefail
    authorize_redis_access_ips
    authorize_database_access_networks
  set -o errexit
  set -o pipefail
  get_database_dump_file
  start_bugsnag

  install_filebeat
  setup_filebeat

  install_metricbeat
  setup_metricbeat

  start_app
  configure_google_fluentd_logging
  configure_log_reader_positioning
  restart_google_fuentd

  configure_logrotate
  create_unattended_upgrades_cronjob
  create_supervisord_cronjob
  update_crontab

  # Setup Vault
  # source /home/vof/vault_token.sh
}

main "$@"
