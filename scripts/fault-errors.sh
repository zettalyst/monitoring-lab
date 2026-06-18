set -eu

docker compose stop mysql mysqld-exporter

printf 'stopped mysql and mysqld-exporter to simulate a SetLog database outage\n'
