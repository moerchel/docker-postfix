#!/bin/bash
# Smoke test of the image with smtp-sink as relay host:
#   - the relay starts, becomes healthy and "postfix check" is clean
#   - a mail from the Docker network is relayed with SASL authentication,
#     the credentials come from SMTP_PASSWORD_FILE
#   - with DEBUG=yes the SMTP password doesn't appear in the log
#   - with the default SMTP_TLS_SECURITY_LEVEL (encrypt) a relay host without
#     STARTTLS gets no mail
#
# Usage: smoke-test.sh IMAGE
# PREFIX (default "smoke-") is put in front of all created container and
# network names. Everything is removed at the end.
#
# smtp-sink and smtp-source are in the Alpine package postfix-stone, which is
# not part of the image. The sink container is started from the same image
# and installs it.
set -euo pipefail

image=$1
p=${PREFIX:-smoke-}
sink=${p}sink
# Test values only, not a real account
user=smoke-user
password=smoke-test-dummy-password

remove_test_objects() {
    docker rm -f "${p}relay-sasl" "${p}relay-tls" "$sink" >/dev/null 2>&1 || true
    docker network rm "${p}net" >/dev/null 2>&1 || true
}
# Leftovers of an aborted earlier run
remove_test_objects

work=$(mktemp -d)
cleanup() {
    remove_test_objects
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
fail() {
    echo "FAILED: $*" >&2
    for c in "${p}relay-sasl" "${p}relay-tls" "$sink"; do
        echo "--- docker logs $c" >&2
        docker logs --tail 40 "$c" >&2 2>&1 || true
    done
    exit 1
}

# Starts a relay container NAME with the given extra docker run arguments
# and waits until it is healthy. The health check interval is shortened so
# the test doesn't wait 60 seconds, the check command is the one of the image.
start_relay() {
    local name=$1 health=
    shift
    docker run -d --name "$name" --network "${p}net" --health-interval 2s \
        -e SERVER_HOSTNAME=relay.smoke.test -e SMTP_SERVER="$sink" -e SMTP_PORT=2525 \
        "$@" "$image" >/dev/null
    for _ in $(seq 1 30); do
        health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
        [ "$health" = healthy ] && break
        [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "$name stopped"
        sleep 2
    done
    echo "$name: $health"
    [ "$health" = healthy ] || fail "$name is not healthy"
}

# Sends a test mail from the sink container (a client in the Docker network)
# to relay NAME and waits for the delivery status in the relay's log
send_mail() {
    local name=$1 rcpt=$2 status=
    docker exec "$sink" smtp-source -m 1 -f sender@example.org -t "$rcpt" \
        -S "Smoke test" "$name:25" || fail "smtp-source could not send to $name"
    for _ in $(seq 1 30); do
        status=$(docker logs "$name" 2>&1 | grep -F "to=<$rcpt>" | grep -F 'status=' | tail -1) || true
        [ -n "$status" ] && break
        sleep 1
    done
    [ -n "$status" ] || fail "no delivery status for $rcpt in the log of $name"
    echo "$status"
}

# All mails the sink received. smtp-sink -d writes one file per mail and
# closes it at the end of the transaction.
sink_mails() { docker exec "$sink" sh -c 'cat /tmp/mails/mail.* 2>/dev/null || true'; }

step "Start smtp-sink as relay host"
docker network create "${p}net" >/dev/null
docker run -d --name "$sink" --network "${p}net" --entrypoint sh "$image" \
    -c 'apk add --no-cache -q postfix-stone && exec smtp-sink -v -u postfix -d /tmp/mails/mail. :2525 10' >/dev/null
for _ in $(seq 1 60); do
    docker exec "$sink" pgrep -x smtp-sink >/dev/null 2>&1 && break
    [ "$(docker inspect -f '{{.State.Running}}' "$sink")" = true ] || fail "sink stopped"
    sleep 1
done
docker exec "$sink" pgrep -x smtp-sink >/dev/null || fail "smtp-sink doesn't run"
echo "smtp-sink runs"

step "Relay with SASL, password from SMTP_PASSWORD_FILE, DEBUG=yes"
printf '%s\n' "$password" > "$work/smtp_password"
chmod 644 "$work/smtp_password"
start_relay "${p}relay-sasl" -e DEBUG=yes -e SMTP_TLS_SECURITY_LEVEL=none \
    -e SMTP_USERNAME="$user" -e SMTP_PASSWORD_FILE=/secrets/smtp_password \
    -v "$work/smtp_password:/secrets/smtp_password:ro"

step "postfix check"
out=$(docker exec "${p}relay-sasl" postfix check 2>&1) || fail "postfix check: $out"
[ -z "$out" ] || fail "postfix check reports: $out"
echo "no findings"

step "Configuration and sasl_passwd"
docker exec "${p}relay-sasl" postconf relayhost smtp_tls_security_level smtp_sasl_auth_enable mynetworks
[ "$(docker exec "${p}relay-sasl" postconf -h relayhost)" = "[$sink]:2525" ] || fail "relayhost"
perms=$(docker exec "${p}relay-sasl" stat -c '%a %U %n' /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.lmdb)
echo "$perms"
[ "$(awk '$1 == 600 && $2 == "root"' <<<"$perms" | wc -l)" -eq 2 ] || fail "sasl_passwd not 600 root"

step "Mail through the relay with SASL"
status=$(send_mail "${p}relay-sasl" sasl@example.org)
grep -qF 'status=sent' <<<"$status" || fail "mail not sent"
grep -qF "relay=$sink" <<<"$status" || fail "mail not sent to $sink"
mails=$(sink_mails)
grep -qF 'X-Rcpt-Args: <sasl@example.org>' <<<"$mails" || fail "mail not in the sink: $mails"
grep -qF 'Subject: Smoke test' <<<"$mails" || fail "subject not in the sink"
echo "mail arrived in the sink"

# smtp-sink -v logs the SMTP conversation. It accepts every AUTH right away,
# so with AUTH LOGIN the credentials themselves are never sent; they are
# checked in the relay's SASL map instead.
docker logs "$sink" 2>&1 | grep -E '^smtp-sink: AUTH ' || fail "the relay didn't authenticate"
creds=$(docker exec "${p}relay-sasl" postmap -q "[$sink]:2525" lmdb:/etc/postfix/sasl_passwd) ||
    fail "no SASL credentials for [$sink]:2525"
[ "$creds" = "$user:$password" ] || fail "wrong SASL credentials in sasl_passwd"
echo "relay authenticated with the credentials from SMTP_PASSWORD_FILE"

step "DEBUG=yes doesn't log the password"
relay_log=$(docker logs "${p}relay-sasl" 2>&1)
[ "$(grep -c '^+' <<<"$relay_log")" -gt 0 ] || fail "DEBUG=yes didn't enable tracing"
if grep -qF "$password" <<<"$relay_log"; then fail "the password is in the log"; fi
echo "$(grep -c '^+' <<<"$relay_log") trace lines, password not in the log"

step "Default TLS level (encrypt) with a relay host without STARTTLS"
start_relay "${p}relay-tls"
docker exec "${p}relay-tls" postconf smtp_tls_security_level
status=$(send_mail "${p}relay-tls" tls@example.org)
grep -qF 'status=deferred' <<<"$status" || fail "mail was not deferred"
grep -qF 'TLS is required, but was not offered' <<<"$status" || fail "deferred for another reason"
if grep -qF 'tls@example.org' <<<"$(sink_mails)"; then fail "mail arrived without TLS"; fi
echo "mail was deferred, nothing sent without TLS"

printf '\nSmoke test passed\n'
