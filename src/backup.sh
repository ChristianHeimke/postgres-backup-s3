#!/bin/sh

set -eu
set -o pipefail

source ./env.sh

echo "Creating backup of $POSTGRES_DATABASE database..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
        > db.dump

backup_size=$(du -h db.dump | cut -f1)
echo "Backup created: size = $backup_size"

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

if [ -n "$GPG_PUBLIC_KEY" ]; then
  echo "Encrypting backup..."
  gpg --import $GPG_PUBLIC_KEY
  gpg --always-trust --encrypt --recipient webmaster@fodjan.de db.dump

  encrypted_backup_size=$(du -h db.dump.gpg | cut -f1)
  echo "Encrypted backup created: size = $encrypted_backup_size"

  rm db.dump
  local_file="db.dump.gpg"
  s3_uri="${s3_uri_base}.gpg"
else
  local_file="db.dump"
  s3_uri="$s3_uri_base"
fi

echo "Uploading backup to $S3_BUCKET..."
aws configure set default.s3.disable_multipart_trailing_checksum true
aws $aws_args s3 cp "$local_file" "$s3_uri"

rm "$local_file"

echo "Backup complete."

if [ -n "$BACKUP_KEEP_DAYS" ]; then
  sec=$((86400*BACKUP_KEEP_DAYS))
  date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  echo "Removing old backups from $S3_BUCKET..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${backups_query}" \
    --output text \
    | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Removal complete."
fi

if [ -n "$PING_UPTIME_URL" ]; then
  wget --spider $PING_UPTIME_URL >/dev/null 2>&1
fi