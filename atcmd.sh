#!/bin/bash
# =============================================================================
# atcmd.sh - Akses AT command modem ZTE G5TS via root shell (port 31337)
#
# Modem Qualcomm ZX29 diakses lewat daemon ZTE (bukan ttyUSB): perintah AT
# dikirim lewat zte_topsw_mc -> at_ctl -> sbusd -> modem.
#
# Pakai (mode perintah):
#   ./atcmd.sh "ATI"
#   ./atcmd.sh "AT+CSQ"
#   ./atcmd.sh "AT+CGSN"
#
# Pakai (mode interaktif, tanpa argumen):
#   ./atcmd.sh
#   at> ATI
#   at> AT+CGMI
#   at> quit
#
# Pakai (mode batch, baca daftar command dari file):
#   ./atcmd.sh -f commands.txt
#   ./atcmd.sh --file commands.txt
#   (satu AT command per baris; baris kosong & diawali # diabaikan)
#
# Environment:
#   G5TS_HOST      alamat router      (default 192.168.0.1)
#   G5TS_SHELL_PORT port root shell   (default 31337)
#
# Catatan: hanya jalankan command READ-ONLY kecuali Anda paham risikonya.
# Command tulis (AT+CFUN=, AT+ZBAND=, AT+ZSET=, AT^RESET, ...) mengubah state
# modem dan bisa memutus koneksi / reset device. Lihat docs/AT_COMMAND_ACCESS.md.
# =============================================================================

set -u
DEV="${G5TS_HOST:-192.168.0.1}"
PORT="${G5TS_SHELL_PORT:-31337}"

# daftar AT command read-only yang umum (untuk bantuan / saran)
RO_COMMANDS="ATI AT+CGMI AT+CGMM AT+CGMR AT+CGSN AT+CIMI AT+CNUM AT+CPIN?
AT+COPS? AT+CREG? AT+CEREG? AT+CGPADDR AT+CGCONTRDP AT+CGACT? AT+CGATT?
AT+CGDCONT? AT+CSQ AT+ZRSSI AT+ZRFSQ AT+ZSINR AT+CESQ
AT+ZBAND? AT+ZLTEBAND? AT+ZNRBAND? AT+ZGSMBAND? AT+ZFDDBAND? AT+ZMODE?
AT+ZMMI? AT+ZGAAT? AT+ZNCELLINFO? AT+CEER"

usage() {
    echo "Pakai:"
    echo "  $0 \"<AT_COMMAND>\"       kirim satu AT command lalu keluar"
    echo "  $0 -f <file>            mode batch (baca daftar command dari file)"
    echo "  $0 --file <file>        sama dengan -f"
    echo "  $0                      mode interaktif"
    echo "  $0 --help               tampilkan bantuan + daftar command read-only"
    echo
    echo "Device : $DEV  (root shell port $PORT)"
    echo "Contoh : $0 \"AT+CSQ\""
}

show_ro() {
    echo "Daftar AT command read-only yang umum:"
    echo "$RO_COMMANDS" | tr ' ' '\n' | sed '/^$/d'
    echo
    echo "Peringatan: hindari command tulis (AT+CFUN=, AT+ZBAND=, AT+ZSET=,"
    echo "AT^RESET, AT+CRSM=, ...) yang mengubah state modem."
}

# cek root shell hidup
check_shell() {
    if ! printf 'id\n' | timeout 6 nc -w4 "$DEV" "$PORT" 2>/dev/null | grep -q 'uid=0'; then
        echo "[!] Root shell di $DEV:$PORT tidak merespons."
        echo "    Jalankan dulu: python3 exploit.py shell"
        exit 1
    fi
}

# kirim satu AT command, cetak respons (tanpa [net] log & banner shell)
send_at() {
    local at="$1"
    # filter baris [net]... dan baris prompt shell "BusyBox"/"/ #"
    timeout 15 nc -w12 "$DEV" "$PORT" 2>/dev/null \
        | grep -vE '^\[net\]|^BusyBox v|^/ #|^$' \
        | sed -n "/${at@Q}/" 2>/dev/null
}

# pengiriman andal: pipe perintah, tandai output, lalu bersihkan
send_at_clean() {
    local at="$1"
    local out
    out=$(printf 'echo __ATBEGIN__; /usr/bin/zte_topsw_mc atcmd "%s" 2>&1; echo __ATEND__\n' "$at" \
        | timeout 15 nc -w12 "$DEV" "$PORT" 2>/dev/null)
    # ambil hanya bagian antara penanda, buang artefak shell/log
    echo "$out" | sed -n '/__ATBEGIN__/,/__ATEND__/p' \
        | sed 's|^/ # __ATBEGIN__|__ATBEGIN__|; s|__ATBEGIN__||; s|__ATEND__||' \
        | grep -vE '^\[net\]|^BusyBox v|^/ #$|^$'
}

run_one() {
    check_shell
    send_at_clean "$1"
}

run_batch() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "[!] File tidak ditemukan: $file"
        exit 1
    fi
    check_shell
    echo "Mode batch dari: $file"
    echo "==============================================="
    local n=0 ok=0 fail=0
    while IFS= read -r line || [ -n "$line" ]; do
        # buang komentar & spasi
        line="${line#"${line%%[![:space:]]*}"}"   # trim kiri
        line="${line%"${line##*[![:space:]]}"}"   # trim kanan
        case "$line" in
            '' ) continue ;;
            \#* ) continue ;;
        esac
        n=$((n+1))
        echo "--- [$n] $line ---"
        local out
        out=$(send_at_clean "$line")
        echo "$out"
        # deteksi error modem
        if echo "$out" | grep -qi 'ERROR'; then
            fail=$((fail+1))
        else
            ok=$((ok+1))
        fi
        echo
    done < "$file"
    echo "==============================================="
    echo "Selesai: $n command, $ok OK, $fail ERROR."
}

run_interactive() {
    check_shell
    echo "Mode interaktif AT command (ketik 'quit' atau Ctrl-C untuk keluar)."
    echo "Device: $DEV:$PORT  |  ketik 'help' untuk daftar command read-only."
    echo
    while true; do
        printf 'at> '
        if ! read -r line; then
            echo
            break
        fi
        case "$line" in
            '' ) continue ;;
            quit|exit ) break ;;
            help|? )
                echo "$RO_COMMANDS" | tr ' ' '\n' | sed '/^$/d'
                continue ;;
        esac
        send_at_clean "$line"
    done
    echo "keluar."
}

case "${1:-}" in
    --help|-h )
        usage
        echo
        show_ro
        ;;
    -f|--file )
        [ $# -lt 2 ] && { echo "[!] Pakai: $0 -f <file>"; exit 2; }
        run_batch "$2"
        ;;
    "" )
        run_interactive
        ;;
    * )
        run_one "$1"
        ;;
esac
