#!/usr/bin/env bash
# vps_test.sh - Test massal NAT VPS (1 IP, banyak port SSH) -> output tabel
# Cek: SSH login, hostname, OS, IPv4, IPv6, ping IPv4 & IPv6 (dari dalam VPS)
#
# Contoh:
#   ./vps_test.sh -H 103.10.10.10 -u root -p 'rahasia' -P 20001-20010
#   ./vps_test.sh -H 103.10.10.10 -k ~/.ssh/id_rsa -P "20001 20005 20010-20015"
#   SSH_PASS='rahasia' ./vps_test.sh -H 103.10.10.10 -P 20001-20050 -j 10

HOST=""; USER_SSH="root"; PASS="${SSH_PASS:-}"; KEY=""; PORTS=""
T4="8.8.8.8"; T6="2001:4860:4860::8888"
JOBS=1; TIMEOUT=10
EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"   # mis. "-o HostKeyAlgorithms=+ssh-rsa" untuk OS lawas

usage() {
  cat <<EOF
Usage: $0 -H <ip> -P <ports> [-u user] [-p pass | -k keyfile] [-j jobs] [-t timeout]
  -H  IP publik NAT (wajib)
  -P  Port: "20001-20010" atau "20001 20005 20010-20015" (wajib)
  -u  User SSH (default: root)
  -p  Password (atau env SSH_PASS)
  -k  Private key
  -j  Jumlah paralel (default: 1)
  -t  Timeout koneksi detik (default: 10)
  -4  Target ping IPv4 (default: $T4)
  -6  Target ping IPv6 (default: $T6)
EOF
  exit 1
}

while getopts "H:P:u:p:k:j:t:4:6:h" o; do
  case $o in
    H) HOST=$OPTARG;; P) PORTS=$OPTARG;; u) USER_SSH=$OPTARG;;
    p) PASS=$OPTARG;; k) KEY=$OPTARG;; j) JOBS=$OPTARG;;
    t) TIMEOUT=$OPTARG;; 4) T4=$OPTARG;; 6) T6=$OPTARG;; *) usage;;
  esac
done
[[ -z $HOST || -z $PORTS ]] && usage
if [[ -z $KEY && -z $PASS ]]; then echo "Isi password (-p) atau key (-k)"; exit 1; fi
if [[ -z $KEY ]] && ! command -v sshpass >/dev/null; then
  echo "sshpass belum ada. Install: apt install sshpass | dnf install sshpass"; exit 1
fi

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else G=; R=; N=; fi

expand_ports() {
  local tok a b
  for tok in $1; do
    if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; seq "$a" "$b"
    else echo "$tok"; fi
  done
}

read -r -d '' REMOTE <<'EOS'
T4="$1"; T6="$2"

h=$(hostname 2>/dev/null); [ -z "$h" ] && h=$(cat /etc/hostname 2>/dev/null)

os=""
[ -r /etc/os-release ] && os=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
[ -z "$os" ] && [ -r /etc/redhat-release ] && os=$(head -n1 /etc/redhat-release)
[ -z "$os" ] && [ -r /etc/issue ] && os=$(head -n1 /etc/issue | sed 's/\\[a-zA-Z]//g')
[ -z "$os" ] && os=$(uname -sr)

if command -v ip >/dev/null 2>&1; then
  v4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  v6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
else
  v4=$(ifconfig 2>/dev/null | awk '/inet addr:/{sub("addr:","",$2);print $2} /inet [0-9]/{print $2}' | grep -v '^127\.' | head -n1)
  v6=$(ifconfig 2>/dev/null | grep -i inet6 | grep -i global | awk '{for(i=2;i<=NF;i++) if($i ~ /^[0-9a-fA-F]*:[0-9a-fA-F:]+(\/[0-9]+)?$/){print $i; exit}}' | sed 's#/.*##' | head -n1)
fi
[ -z "$v4" ] && v4=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1)

p4=FAIL; p6=FAIL; note=""
if command -v ping >/dev/null 2>&1 || command -v ping6 >/dev/null 2>&1; then
  if [ -n "$v4" ]; then ping -c 2 -W 3 "$T4" >/dev/null 2>&1 && p4=OK; else note="no IPv4"; fi
  if [ -n "$v6" ]; then
    { ping -6 -c 2 -W 3 "$T6" >/dev/null 2>&1 || ping6 -c 2 -W 3 "$T6" >/dev/null 2>&1; } && p6=OK
  else note="$note${note:+, }no IPv6"; fi
else
  note="ping tidak terinstall"
fi

echo "HOSTNAME=$h"
echo "OS=$os"
echo "IPV4=$v4"
echo "IPV6=$v6"
echo "PING4=$p4"
echo "PING6=$p6"
echo "NOTE=$note"
EOS

test_port() {
  local port=$1 out rc
  local opts=(-p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o ConnectTimeout="$TIMEOUT" -o LogLevel=ERROR -o ServerAliveInterval=5
              -o ServerAliveCountMax=3)
  opts+=($EXTRA_OPTS)

  if [[ -n $KEY ]]; then
    out=$(ssh "${opts[@]}" -i "$KEY" -o BatchMode=yes "$USER_SSH@$HOST" \
          "sh -s -- '$T4' '$T6'" <<<"$REMOTE" 2>&1); rc=$?
  else
    out=$(SSHPASS="$PASS" sshpass -e ssh "${opts[@]}" \
          -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
          "$USER_SSH@$HOST" "sh -s -- '$T4' '$T6'" <<<"$REMOTE" 2>&1); rc=$?
  fi

  if (( rc != 0 )) || ! grep -q '^HOSTNAME=' <<<"$out"; then
    local reason; reason=$(tail -n1 <<<"$out" | tr '\t' ' ' | cut -c1-50)
    printf '%s\tFAIL\t-\t-\t-\t-\t-\t-\tFAIL\t%s\n' "$port" "${reason:--}" >"$TMPD/$port"
    return
  fi

  local h os v4 v6 p4 p6 note k v
  while IFS='=' read -r k v; do
    case $k in HOSTNAME) h=$v;; OS) os=$v;; IPV4) v4=$v;; IPV6) v6=$v;;
               PING4) p4=$v;; PING6) p6=$v;; NOTE) note=$v;; esac
  done <<<"$out"

  local res=OK
  [[ $p4 == OK && $p6 == OK ]] || res=FAIL
  printf '%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$port" \
    "${h:--}" "$(cut -c1-30 <<<"${os:--}")" "${v4:--}" "${v6:--}" "$p4" "$p6" "$res" "${note:--}" \
    >"$TMPD/$port"
}

TMPD=$(mktemp -d); TABLE="$TMPD.tsv"; trap 'rm -rf "$TMPD" "$TABLE"' EXIT
echo "Testing $HOST | user: $USER_SSH | ports: $PORTS | jobs: $JOBS" >&2

for p in $(expand_ports "$PORTS"); do
  test_port "$p" &
  while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.2; done
done
wait

{
  printf 'PORT\tSSH\tHOSTNAME\tOS\tIPV4\tIPV6\tPING4\tPING6\tRESULT\tNOTE\n'
  for f in $(ls "$TMPD" | sort -n); do cat "$TMPD/$f"; done
} > "$TABLE"

if command -v column >/dev/null; then
  column -t -s $'\t' "$TABLE"
else
  cat "$TABLE"
fi | sed -e "s/\bOK\b/${G}OK${N}/g" -e "s/\bFAIL\b/${R}FAIL${N}/g"

total=$(( $(wc -l <"$TABLE") - 1 ))
pass=$(awk -F'\t' 'NR>1 && $9=="OK"' "$TABLE" | wc -l)
failed=$((total - pass))
echo
echo "Total: $total | ${G}OK: $pass${N} | ${R}FAIL: $failed${N}"
(( failed > 0 )) && exit 1 || exit 0
