#!/usr/bin/env bash
set -Eeuo pipefail

echo "Extracting template image..."

DST="/images"
OUT="/tmp/extract"

rm -rf "$OUT"
rm -rf "$DST"

mkdir -p "$OUT"
mkdir -p "$DST"

if [ ! -f "$1" ] || [ ! -s "$1" ]; then
  error "Could not find image file \"$1\"." && exit 10
fi

START=$(sfdisk -l "$1" | grep -i -m 1 "EFI System" | awk '{print $2}')
mcopy -bspmQ -i "$1@@${START}S" ::EFI "$OUT"

echo "Creating OpenCore image..."

START=2048
COUNT=522207
SIZE=268435456

FILE="OpenCore.img"
IMG="/tmp/$SIZE.img"
NAME=$(basename "$IMG")

rm -f "$IMG"

if ! truncate -s "$SIZE" "$IMG"; then
  rm -f "$IMG"
  error "Could not allocate file $IMG for the OpenCore image." && exit 11
fi

PART="/tmp/partition.fdisk"

{       echo "label: gpt"
        echo "label-id: 1ACB1E00-3B8F-4B2A-86A4-D99ED21DCAEB"
        echo "device: $NAME"
        echo "unit: sectors"
        echo "first-lba: 34"
        echo "last-lba: 524254"
        echo "sector-size: 512"
        echo ""
        echo "${NAME}1 : start=$START, size=$COUNT, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=05157F6E-0AE8-4D1A-BEA5-AC172453D02C, name=\"primary\""

} > "$PART"

sfdisk -q "$IMG" < "$PART"

echo "drive c: file=\"$IMG\" partition=0 offset=1048576" > /etc/mtools.conf

mformat -F -M 512 -c 4 -T "$COUNT" -v "EFI" "C:"

echo "Copying files to image..."

mcopy -bspmQ "$OUT/EFI" "C:"

mv -f "$IMG" "$DST/$FILE"

echo "Finished succesfully!"
