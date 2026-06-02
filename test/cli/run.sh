#!/bin/sh

set -e

cd $(dirname $0)
. ../util.sh
current_test=$(basename $(pwd))

docker network create test_network
docker volume create backup_data
docker volume create app_data
# This volume is created to test whether empty directories are handled
# correctly. It is not supposed to hold any data.
docker volume create empty_data

# run s3 server and offen containers
docker run -d -q \
  --name s3-server \
  --network test_network \
  --env AWS_ACCESS_KEY_ID=test \
  --env AWS_SECRET_ACCESS_KEY="test1234" \
  --env S3_BUCKET=backup \
  -v backup_data:/data \
  chrislusf/seaweedfs:4.29@sha256:d47c7ee99fcb951351d7194915f4e3a5ea604a8e8871183d713907dec4fb9bf5 \
  mini -dir /data

docker run -d -q \
  --name offen \
  --network test_network \
  -v app_data:/var/opt/offen/ \
  offen/offen:latest

sleep 10

docker run --rm -q \
  --network test_network \
  -v app_data:/backup/app_data \
  -v empty_data:/backup/empty_data \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --env AWS_ACCESS_KEY_ID=test \
  --env AWS_SECRET_ACCESS_KEY="test1234" \
  --env AWS_ENDPOINT=s3-server:8333 \
  --env AWS_ENDPOINT_PROTO=http \
  --env AWS_S3_BUCKET_NAME=backup \
  --env BACKUP_FILENAME=test.tar.gz \
  --env BACKUP_FROM_SNAPSHOT=true \
  --entrypoint backup \
  offen/docker-volume-backup:${TEST_VERSION:-canary}

# verify db file and empty directory are present in backup
docker run --rm -q \
  --env AWS_ENDPOINT_URL="http://s3-server:8333" \
  --env AWS_ACCESS_KEY_ID=test \
  --env AWS_SECRET_ACCESS_KEY="test1234" \
  --env AWS_DEFAULT_REGION=us-east-1 \
  --env AWS_S3_USE_PATH_STYLE=true \
  --network test_network \
  amazon/aws-cli:2.34.54 \
  s3 cp s3://backup/test.tar.gz - | \
docker run --rm -i \
  alpine \
  ash -c 'tar -xzf - -C /tmp && test -f /tmp/backup/app_data/offen.db && test -d /tmp/backup/empty_data'

pass "Found relevant files in untared remote backup."

# This test does not stop containers during backup. This is happening on
# purpose in order to cover this setup as well.
expect_running_containers "2"

docker rm $(docker stop s3-server offen)
docker volume rm backup_data app_data
docker network rm test_network
