{
  writeShellScriptBin
}: writeShellScriptBin "mk-volume" ''
  set -euxo pipefail

  if [ "$#" -lt 2 ]; then
    echo "invalid number of args"
    exit 1
  fi;

  OUTDIR=./result

  if [ -d "$OUTDIR" ]; then
    echo "directory already exists"
    exit 2
  fi

  mkdir "$OUTDIR"

  NAME="$1"
  SIZE="$2"

  FS=ext4
  if [ "$#" -ge 3 ]; then
    FS="$3"
  fi;

  VOLUME=""
  if [ "$#" -ge 4 ]; then
    VOLUME="$4"
  fi;

  IMAGE_PATH="$OUTDIR/$NAME.img"

  truncate --size=$SIZE $IMAGE_PATH
  mkfs.$FS $IMAGE_PATH

  if [ ! -z "$VOLUME" ]; then
    mkdir "$OUTDIR/mnt"
    mount -t auto -o loop $IMAGE_PATH "$OUTDIR/mnt"
    cp -r $VOLUME "$OUTDIR/mnt/"
    umount $OUTDIR/mnt
    rmdir $OUTDIR/mnt
  fi
''
