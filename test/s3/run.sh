#!/bin/sh

set -e

cd "$(dirname "$0")"
. ../util.sh
current_test=$(basename $(pwd))

docker compose up -d --quiet-pull --wait  # "--wait" blocks until all services are healthy

docker compose exec backup backup

expect_running_containers "4"

# download backup from s3 server, unpack it and check if files are present
docker exec s3-s3-client-1 aws s3 \
  cp s3://backup/test-hostnametoken.tar.gz - | \
docker run --rm -i \
  alpine \
  ash -c 'tar -xzf - -C /tmp && test -f /tmp/backup/app_data/offen.db'

pass "Found relevant files in untared remote backups."

# The second part of this test checks if backups get deleted when the retention
# is set to 0 days (which it should not as it would mean all backups get deleted)
BACKUP_RETENTION_DAYS="0" docker compose up -d --wait

docker compose exec backup backup

# check if backup is present on s3 server
docker exec s3-s3-client-1 aws \
  s3api head-object --bucket backup --key test-hostnametoken.tar.gz > /dev/null

pass "Remote backups have not been deleted."

# The third part of this test checks if old backups get deleted when the retention
# is set to 7 days (which it should)

BACKUP_RETENTION_DAYS="7" docker compose up -d --wait

info "Create first backup with no prune"
docker compose exec backup backup

# todo add documentation and explanation
docker run --rm \
  --network s3_default \
  --privileged \
  --device /dev/fuse \
  --entrypoint sh \
  chrislusf/seaweedfs \
  -c 'set -eu
  mkdir -p /mnt/seaweedfs
  weed mount -filer=s3-server:8888 -dir=/mnt/seaweedfs &
  sleep 5
  now=$(date +%s)
  old=$((now - 1209600))
  touch -d "@$old" /mnt/seaweedfs/buckets/backup/test-hostnametoken-old.tar.gz
  umount /mnt/seaweedfs'

info "Create second backup and prune"
docker compose exec backup backup

# verify new file is still present
docker exec s3-s3-client-1 aws \
  s3api head-object --bucket backup --key test-hostnametoken.tar.gz > /dev/null
# and old one is not
! docker exec s3-s3-client-1 aws \
  s3api head-object --bucket backup --key test-hostnametoken-old.tar.gz > /dev/null

pass "Old remote backup has been pruned, new one is still present."
