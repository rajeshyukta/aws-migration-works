#!/usr/bin/env bash
# Generate a one-time Root CA + CA-signed leaf cert for domains.rajesh.in on Web-1,
# install leaf+CA chain in Caddy (/etc/caddy/certs/domains.rajesh.in.{crt,key}),
# permanently delete the Root CA private key, and export ONLY the public Root CA cert.
set -Eeuo pipefail

OUT_CA="${OUT_CA:?OUT_CA must be set}"
CERT_DIR=/etc/caddy/certs
LEAF_CRT=$CERT_DIR/domains.rajesh.in.crt
LEAF_KEY=$CERT_DIR/domains.rajesh.in.key

WORK=$(mktemp -d /tmp/web1-ca.XXXXXX)
chmod 0700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
CN = NextDP Local Root CA (domains.rajesh.in)
O = NextDP Temporary CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign

[v3_leaf]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = domains.rajesh.in
DNS.2 = www.domains.rajesh.in
EOF

echo "=== [1/4] Generate temporary Root CA & CA-signed leaf cert (60-day validity) ==="
openssl genrsa -out "$WORK/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$WORK/ca.key" -sha256 -days 90 \
  -config "$WORK/openssl.cnf" -extensions v3_ca -out "$WORK/ca.crt"

openssl genrsa -out "$WORK/leaf.key" 2048 2>/dev/null
openssl req -new -key "$WORK/leaf.key" -subj "/CN=domains.rajesh.in/O=NextDP/" \
  -out "$WORK/leaf.csr"
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -out "$WORK/leaf.crt" -days 60 -sha256 \
  -extfile "$WORK/openssl.cnf" -extensions v3_leaf 2>/dev/null

# Verify chain & immediately destroy CA private key so no other cert can ever be signed
openssl verify -CAfile "$WORK/ca.crt" "$WORK/leaf.crt"
rm -f "$WORK/ca.key" "$WORK/ca.srl" "$WORK/leaf.csr"

echo "=== [2/4] Install fullchain & key in /etc/caddy/certs and reload Caddy ==="
sudo install -d -o root -g caddy -m 0750 "$CERT_DIR"
cat "$WORK/leaf.crt" "$WORK/ca.crt" > "$WORK/fullchain.crt"
sudo install -o root -g caddy -m 0644 "$WORK/fullchain.crt" "$LEAF_CRT"
sudo install -o root -g caddy -m 0640 "$WORK/leaf.key" "$LEAF_KEY"

sudo -u caddy caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo systemctl reload caddy
sleep 1

echo "=== [3/4] Verify verified HTTPS (using --cacert, NO -k insecure flag) ==="
CODE=$(curl --cacert "$WORK/ca.crt" --resolve domains.rajesh.in:443:127.0.0.1 -s -o /dev/null -w '%{http_code}' https://domains.rajesh.in/login)
echo "  Verified TLS https://domains.rajesh.in/login -> HTTP $CODE"
[ "$CODE" = "200" ] || { echo "FATAL: expected HTTP 200 under CA verification" >&2; exit 1; }

openssl x509 -in "$WORK/ca.crt" -noout -subject -fingerprint -sha256 -dates

echo "=== [4/4] Stage public Root CA cert (no private key) ==="
install -m 0644 "$WORK/ca.crt" "$OUT_CA"
