#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# First-boot bootstrap for the update server.
#
# Runs on EVERY boot (systemd oneshot) and picks one of three states. Choosing
# the wrong state is the worst thing this script can do: re-running the init
# commands on an already-provisioned server would mint a NEW TUF root key and
# orphan every enrolled device. So the ordering of these tests matters, and the
# cheapest, most local evidence (files on the data volume) is checked first.
#
#   State A  the data volume already holds a provisioned datadir  -> do nothing
#   State B  the datadir is empty but secrets are escrowed        -> restore
#   State C  no datadir and no escrow                             -> initialize
#
# Bootstrap ordering is dictated by the server itself:
#   * auth-init writes ONLY auth/hmac.secret and no auth-config.json, and serve
#     then fails in auth.NewProvider -> GetAuthConfig. So an auth-config.json
#     must be supplied separately; that is what the auth-config secret is for.
#   * InitHmacSecret() errors if auth/hmac.secret already exists.
#   * tuf-init requires the HMAC secret to pre-exist (the TUF role keys are
#     encrypted with a key derived from it via HKDF).
#   * pki-init calls AssertCleanPki() and errors if ANY file in certs/ exists.
# Each step below is therefore guarded by its own file test, so a crash midway
# through State C leaves a resumable datadir rather than a wedged one.

set -euo pipefail

DATADIR=/data
ENV_FILE=/etc/fioserver/env
FIOSERVER=/usr/local/bin/fioserver
MARKER="${DATADIR}/.bootstrap-state"

log() { echo "bootstrap: $*"; }
die() { echo "bootstrap: ERROR: $*" >&2; exit 1; }

[ -r "$ENV_FILE" ] || die "missing $ENV_FILE (should be written by user_data)"
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${FIOSERVER_HOSTNAME:?must be set in $ENV_FILE}"
: "${FIOSERVER_FACTORY:?must be set in $ENV_FILE}"
: "${FIOSERVER_SECRET_PREFIX:?must be set in $ENV_FILE}"
: "${AWS_REGION:?must be set in $ENV_FILE}"
TLS_EXPIRY_DAYS="${FIOSERVER_TLS_EXPIRY_DAYS:-3650}"

# Devices reach the gateway by a name that may differ from the UI's: with load
# balancers the UI is behind an ALB and the gateway behind an NLB, and one DNS
# record cannot alias to both. This is the name that goes into the certificate.
GATEWAY_HOSTNAME="${FIOSERVER_GATEWAY_HOSTNAME:-$FIOSERVER_HOSTNAME}"

export AWS_DEFAULT_REGION="$AWS_REGION"

secret_id() { echo "${FIOSERVER_SECRET_PREFIX}/$1"; }

# Print a secret's value, or nothing if it is absent/empty. A missing secret is
# a normal, expected condition here (it is how State C is detected), so this
# must not trip `set -e`.
secret_get() {
    aws secretsmanager get-secret-value \
        --secret-id "$(secret_id "$1")" \
        --query SecretString --output text 2>/dev/null || true
}

# Secrets Manager caps a secret at 64 KiB. certs/ and tuf/ hold only keys,
# certificates and TUF metadata, so they are far below that -- but fail loudly
# rather than let AWS truncate an escrow we may later need to restore from.
secret_put() {
    local name="$1" file="$2" size
    size=$(wc -c <"$file")
    if [ "$size" -gt 65536 ]; then
        die "$name is ${size} bytes, over the 64KiB Secrets Manager limit"
    fi
    # file:// (not fileb://) -- these payloads are already base64 ASCII, and
    # passing them via a file keeps them off the process command line.
    aws secretsmanager put-secret-value \
        --secret-id "$(secret_id "$name")" \
        --secret-string "file://${file}" >/dev/null
    log "escrowed $name (${size} bytes)"
}

mountpoint -q "$DATADIR" || die "$DATADIR is not a mount point"

# ---------------------------------------------------------------- State A ----
# Both the TUF root key and the HMAC secret that decrypts it are present, so
# this datadir is provisioned. Never touch it.
if [ -f "${DATADIR}/tuf/keys/root.key" ] && [ -f "${DATADIR}/auth/hmac.secret" ]; then
    log "datadir already provisioned; nothing to do"
    echo "A $(date -u +%FT%TZ)" >"$MARKER"
    exit 0
fi

# ---------------------------------------------------------------- State B ----
# Empty volume, but an escrow exists: this is a replacement instance or a
# rebuild onto a fresh volume. Restore rather than re-initialize, so the
# factory identity and every enrolled device survive.
HMAC_B64="$(secret_get hmac-secret)"
if [ -n "$HMAC_B64" ]; then
    log "escrow found; restoring PKI and TUF state from Secrets Manager"
    install -d -m 0750 "${DATADIR}/auth" "${DATADIR}/certs" "${DATADIR}/tuf"

    # The HMAC secret is 64 bytes of raw binary, so it is escrowed base64-encoded.
    umask 077
    echo "$HMAC_B64" | base64 -d >"${DATADIR}/auth/hmac.secret"
    chmod 0600 "${DATADIR}/auth/hmac.secret"

    AUTH_CONFIG="$(secret_get auth-config)"
    if [ -n "$AUTH_CONFIG" ]; then
        printf '%s' "$AUTH_CONFIG" >"${DATADIR}/auth/auth-config.json"
    else
        # Terraform only seeds this secret when the operator supplied
        # auth_config_json. If it is empty, State C generated the config
        # locally and escrowed it -- so an empty secret here means the escrow
        # is incomplete, not that local auth was intended.
        die "auth-config secret is empty; cannot restore"
    fi
    chmod 0640 "${DATADIR}/auth/auth-config.json"

    # The archives are created with `tar -C $DATADIR certs` / `... tuf`, so
    # their entries are already prefixed with the directory name. Extract at
    # the datadir root, not into the directory itself.
    for name in certs-archive tuf-archive; do
        val="$(secret_get "$name")"
        [ -n "$val" ] || die "$name secret is empty; cannot restore"
        echo "$val" | base64 -d | tar -xzf - -C "$DATADIR"
        log "restored $name"
    done

    # Re-assert restrictive modes: tar preserves them, but a hand-edited escrow
    # might not.
    find "${DATADIR}/certs" "${DATADIR}/tuf" -type f -name '*.key' -exec chmod 0600 {} +

    # Deliberately NOT restored: db.sqlite. The escrow preserves the server's
    # identity, not its data. If the volume was lost, recover the database from
    # a DLM snapshot; otherwise device and update records are gone even though
    # the PKI is intact.
    log "restore complete (db.sqlite not restored; see the README)"
    echo "B $(date -u +%FT%TZ)" >"$MARKER"
    exit 0
fi

# ---------------------------------------------------------------- State C ----
# Genuinely first boot.
log "no datadir and no escrow; initializing a new server"

if [ ! -f "${DATADIR}/auth/hmac.secret" ]; then
    log "running auth-init"
    "$FIOSERVER" --datadir "$DATADIR" auth-init
fi

if [ ! -f "${DATADIR}/auth/auth-config.json" ]; then
    AUTH_CONFIG="$(secret_get auth-config)"
    if [ -n "$AUTH_CONFIG" ]; then
        log "writing operator-supplied auth-config.json"
        printf '%s' "$AUTH_CONFIG" >"${DATADIR}/auth/auth-config.json"
        chmod 0640 "${DATADIR}/auth/auth-config.json"
    else
        log "no auth-config supplied; configuring local auth with a generated admin"
        cat >"${DATADIR}/auth/auth-config.json" <<'EOF'
{
  "Type": "local",
  "SessionTimeoutHours": 48,
  "Config": {
    "MinPasswordLength": 12,
    "PasswordAgeDays": 0,
    "PasswordHistory": 0,
    "PasswordComplexityRules": {
      "RequireUppercase": true,
      "RequireLowercase": true,
      "RequireDigit": true,
      "RequireSpecialChar": ""
    }
  },
  "NewUserDefaultScopes": [
    "devices:create",
    "devices:delete",
    "devices:read",
    "devices:read-update",
    "updates:read",
    "updates:read-update",
    "users:create",
    "users:delete",
    "users:read",
    "users:read-update"
  ]
}
EOF
        chmod 0640 "${DATADIR}/auth/auth-config.json"

        # Satisfy the complexity rules above deterministically rather than
        # hoping a random string happens to contain every required class.
        ADMIN_PW="Fio$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)1a"
        PW_TMP="$(mktemp)"
        printf '%s' "$ADMIN_PW" >"$PW_TMP"
        aws secretsmanager put-secret-value \
            --secret-id "$(secret_id admin-password)" \
            --secret-string "file://${PW_TMP}" >/dev/null
        rm -f "$PW_TMP"
        log "escrowed the generated admin password"

        "$FIOSERVER" --datadir "$DATADIR" user-add \
            --username admin --password "$ADMIN_PW"
        unset ADMIN_PW

        # Escrow the generated config too. Terraform only seeds the
        # auth-config secret when the operator passed auth_config_json, so
        # without this a later restore (State B) would find it empty and have
        # no auth config to install.
        secret_put auth-config "${DATADIR}/auth/auth-config.json"
    fi
fi

if [ ! -f "${DATADIR}/certs/tls.pem" ]; then
    # --dnsname becomes the first DNS SAN of certs/tls.pem, and the server
    # derives every device-facing URL from it (DgUrl is
    # "https://<SAN>:8443", and each enrolled device's sota.toml is built from
    # that). It must be the real public hostname, and it is effectively
    # immutable once a device has enrolled.
    #
    # The expiry matters more than it looks: the gateway REFUSES TO START once
    # this leaf expires, and nothing renews it automatically. Hence the
    # long default.
    log "running pki-init for ${GATEWAY_HOSTNAME} (factory ${FIOSERVER_FACTORY})"
    "$FIOSERVER" --datadir "$DATADIR" pki-init \
        --dnsname "$GATEWAY_HOSTNAME" \
        --factory "$FIOSERVER_FACTORY" \
        --tlsexpirydays "$TLS_EXPIRY_DAYS"
fi

if [ ! -f "${DATADIR}/tuf/keys/root.key" ]; then
    log "running tuf-init"
    "$FIOSERVER" --datadir "$DATADIR" tuf-init
fi

log "escrowing secrets to Secrets Manager"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

base64 -w0 <"${DATADIR}/auth/hmac.secret" >"${TMP}/hmac"
secret_put hmac-secret "${TMP}/hmac"

# Archive whole directories rather than individual keys. A restore needs more
# than the roots of trust: devices authenticate against cas.pem and
# device-ca.crt, and the TUF metadata chain must match the keys. pki-init
# cannot rebuild a partial certs/ (AssertCleanPki refuses any pre-existing
# file) and there is no re-issue-leaf subcommand, so a faithful restore means
# keeping everything.
tar -czf - -C "${DATADIR}" certs | base64 -w0 >"${TMP}/certs"
secret_put certs-archive "${TMP}/certs"

tar -czf - -C "${DATADIR}" tuf | base64 -w0 >"${TMP}/tuf"
secret_put tuf-archive "${TMP}/tuf"

echo "C $(date -u +%FT%TZ)" >"$MARKER"
log "initialization complete"
