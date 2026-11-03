#!/bin/bash
# =============================================================================
# backup_all.sh - Backup LENGKAP ZTE G5TS via root shell (port 31337)
#
# Mekanisme: device buka server file (tcpsvd) -> host tarik pakai nc.
# Read-only terhadap NAND (pakai /dev/mtdXro dan /dev/ubiN_M).
#
# Pakai:
#   ./backup_all.sh <folder_tujuan>
# Contoh:
#   ./backup_all.sh /root/ANEWPROJECT/REAL/backup_baru
# =============================================================================

set -u
DEV="${G5TS_HOST:-192.168.0.1}"
SHELL_PORT="${G5TS_SHELL_PORT:-31337}"
OUT="${1:-/root/ANEWPROJECT/REAL/backup_baru}"

mkdir -p "$OUT"
cd "$OUT" || { echo "gagal masuk $OUT"; exit 1; }

echo "==============================================="
echo " Backup ke : $OUT"
echo " Device    : $DEV   (root shell port $SHELL_PORT)"
echo "==============================================="

# cek koneksi shell (kirim 'id' untuk pastikan shell hidup)
if ! printf 'id\n' | timeout 6 nc -w4 "$DEV" "$SHELL_PORT" 2>/dev/null | grep -q 'uid=0'; then
    echo "[!] Root shell di $DEV:$SHELL_PORT tidak merespons."
    echo "    Jalankan dulu: python3 exploit.py shell"
    echo "    (dari folder zte-g5ts-privilege-escalation)"
    exit 1
fi

PORT=46500
PORT=$((PORT-1))

# fungsi: tarik satu sumber device ("/dev/mtd14ro" atau "/dev/ubi1_0") ke file
pull() {
    local src="$1" outfile="$2"
    PORT=$((PORT+1))
    [ "$PORT" -gt 49000 ] && PORT=46500
    nc -w3 "$DEV" "$SHELL_PORT" <<EOF >/dev/null 2>&1
pkill -f "tcpsvd 0.0.0.0 $PORT " 2>/dev/null
tcpsvd 0.0.0.0 $PORT cat $src &
EOF
    sleep 1
    nc -w 120 "$DEV" "$PORT" > "$outfile" 2>/dev/null
    local sz
    sz=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
    printf "  %-28s -> %-22s %s bytes\n" "$src" "$outfile" "$sz"
}

echo
echo "=== 1. Partisi MTD (mtd0..mtd22) ==="
for n in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
    pull "/dev/mtd${n}ro" "mtd${n}.bin"
done

echo
echo "=== 2. Volume UBI ==="
pull "/dev/ubi1_0" "ubi1_0.etc_rw.bin"
pull "/dev/ubi1_1" "ubi1_1.rootfs_data.bin"
pull "/dev/ubi3_0" "ubi3_0.cache.bin"
pull "/dev/ubi4_0" "ubi4_0.manufacture_data.bin"

echo
echo "=== 3. Filesystem penting (tar) ==="
# buat tar di device lalu tarik
nc -w5 "$DEV" "$SHELL_PORT" <<'EOF' >/dev/null 2>&1
tar czf /tmp/fs_root.tar.gz -C / etc etc_ro etc_rw www usr/bin usr/lib config 2>/dev/null
sync
EOF
sleep 3
pull "/tmp/fs_root.tar.gz" "fs_root.tar.gz"

echo
echo "=== 4. Checksum ==="
md5sum *.bin fs_root.tar.gz 2>/dev/null > MD5SUMS.txt
wc -l MD5SUMS.txt

echo
echo "=== 5. Ringkasan ukuran ==="
ls -l --block-size=K *.bin fs_root.tar.gz 2>/dev/null | awk '{print $5, $9}'
echo
echo "SELESAI. Backup di: $OUT"
echo "Untuk membandingkan dengan backup lama:"
echo "  cmp $OUT/mtd18.bin /root/ANEWPROJECT/REAL/backup/mtd18.bin"
echo "  cmp -l <lama> <baru> | head     # cari offset beda"
