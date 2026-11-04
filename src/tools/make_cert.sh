#!/usr/bin/env bash
# 生成本地 CA + 服务器证书，供 https:8443 使用。
# 用 CA 签发（而不是裸自签）是为了 PC 端把 ca.pem 装进信任库后不再弹拦截页。
# 手机端不需要它，手机走隧道拿真证书。
# 产物：src/certs/{ca.pem,cert.pem,key.pem}
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../certs"
mkdir -p "$OUT"

if [ -f "$OUT/cert.pem" ] && [ -f "$OUT/ca.pem" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  证书已存在，跳过（FORCE=1 可重新生成）"
  exit 0
fi

SAN="DNS:localhost,DNS:$(hostname),IP:127.0.0.1"
for ip in $(hostname -I 2>/dev/null || true); do
  case "$ip" in *:*) continue;; esac
  SAN="$SAN,IP:$ip"
done
for ip in "$@"; do
  case ",$SAN," in *",IP:$ip,"*) ;; *) SAN="$SAN,IP:$ip";; esac
done

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$OUT/ca.key" -out "$OUT/ca.pem" \
  -subj "/C=CN/O=Quectel Pi Demo/CN=Quectel Pi Demo Local CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/key.pem" -out "$OUT/cert.csr" \
  -subj "/C=CN/O=Quectel Pi Demo/CN=webrtc-av-call" >/dev/null 2>&1

cat > "$OUT/leaf.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN
EXT

openssl x509 -req -in "$OUT/cert.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca.key" \
  -CAcreateserial -days 730 -out "$OUT/cert.pem" -extfile "$OUT/leaf.ext" >/dev/null 2>&1
rm -f "$OUT/cert.csr" "$OUT/leaf.ext" "$OUT/ca.srl"
chmod 600 "$OUT/key.pem" "$OUT/ca.key"

echo "  证书已生成：$OUT"
echo "  $(openssl x509 -in "$OUT/cert.pem" -noout -ext subjectAltName | tail -1 | tr -s ' ')"
