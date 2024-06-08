#!/usr/bin/env bash
set -Eeuo pipefail

DST="/images"
OUT="/tmp/extract"

rm -rf "$OUT"
rm -rf "$DST"

mkdir -p "$OUT"
mkdir -p "$DST"

echo "Extracting template image..."

if [ ! -f "$1" ] || [ ! -s "$1" ]; then
  echo "Could not find image file \"$1\"." && exit 10
fi

START=$(sfdisk -l "$1" | grep -i -m 1 "EFI System" | awk '{print $2}')
mcopy -bspmQ -i "$1@@${START}S" ::EFI "$OUT"

echo "Building OpenCore image..."

cp "$2" "$OUT/EFI/OC/"

MB=256
CLUSTER=4
START=2048
SECTOR=512
FIRST_LBA=34

SIZE=$(( MB*1024*1024 ))
OFFSET=$(( START*SECTOR ))
TOTAL=$(( SIZE-(FIRST_LBA*SECTOR) ))
LAST_LBA=$(( TOTAL/SECTOR ))
COUNT=$(( LAST_LBA-(START-1) ))

FILE="OpenCore.img"
IMG="/tmp/$FILE"
rm -f "$IMG"

if ! truncate -s "$SIZE" "$IMG"; then
  rm -f "$IMG"
  echo "Could not allocate file $IMG for the OpenCore image." && exit 11
fi

PART="/tmp/partition.fdisk"

{       echo "label: gpt"
        echo "label-id: 1ACB1E00-3B8F-4B2A-86A4-D99ED21DCAEB"
        echo "device: $FILE"
        echo "unit: sectors"
        echo "first-lba: $FIRST_LBA"
        echo "last-lba: $LAST_LBA"
        echo "sector-size: $SECTOR"
        echo ""
        echo "${FILE}1 : start=$START, size=$COUNT, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=05157F6E-0AE8-4D1A-BEA5-AC172453D02C, name=\"primary\""

} > "$PART"

sfdisk -q "$IMG" < "$PART"

echo "drive c: file=\"$IMG\" partition=0 offset=$OFFSET" > /etc/mtools.conf

mformat -F -M "$SECTOR" -c "$CLUSTER" -T "$COUNT" -v "EFI" "C:"

echo "Copying files to image..."

mcopy -bspmQ "$OUT/EFI" "C:"
rm -rf "$OUT"

echo "Compressing image..."

gzip -c "$IMG" > "$DST/$FILE.gz"
rm -f "$IMG"

echo "Finished succesfully!"
