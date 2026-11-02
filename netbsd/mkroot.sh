#!/bin/sh
# Build a small FFS root image from the NetBSD 3.1 evbsh5 base set:
#   mkroot.sh <base.tgz> <tooldir> <output image>
# The tree holds the static /rescue tools, symlinks into it, a minimal
# /etc and device nodes from root.spec.  Image size 12 MB.
set -e
BASE=$1; TOOLS=$2; OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d)
cd "$ROOT"
tar xzf "$BASE" ./rescue
mkdir -p bin sbin etc dev tmp var/run mnt usr/bin usr/sbin libexec kern root
ln -s ../rescue/sh bin/sh
ln -s ../rescue/init sbin/init
for c in cat chmod cp date dd df echo ed expr hostname kill ksh ln ls mkdir mv pax tar ps pwd rm rmdir sleep stty sync test; do
	ln -s ../rescue/$c bin/$c
done
for c in mknod mount umount reboot halt shutdown ifconfig route sysctl dmesg disklabel newfs fsck fsck_ffs mount_ffs mount_kernfs mount_mfs swapctl ping; do
	ln -s ../rescue/$c sbin/$c
done
cat > etc/rc <<'RC'
#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/rescue
mount -t kernfs kernfs /kern 2>/dev/null
hostname cayman
ifconfig lo0 127.0.0.1 up
RC
chmod +x etc/rc
printf 'console\t"/usr/libexec/getty default"\tvt100\toff secure\n' > etc/ttys
echo "root::0:0::0:0:Charlie &:/root:/bin/sh" > etc/master.passwd
echo "root:*:0:0:Charlie &:/root:/bin/sh" > etc/passwd
echo "wheel:*:0:root" > etc/group
"$TOOLS/bin/nbmakefs" -t ffs -s 12m -F "$HERE/root.spec" -o density=4096 "$OUT" "$ROOT"
rm -rf "$ROOT"
