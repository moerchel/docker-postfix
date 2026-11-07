#!/bin/bash

[ "${DEBUG}" == "yes" ] && set -x

function add_config_value() {
  local key=${1}
  local value=${2}
  [ "${key}" == "" ] && echo "ERROR: No key set !!" && exit 1
  [ "${value}" == "" ] && echo "ERROR: No value set for ${key} !!" && exit 1

  echo "Setting configuration option ${key} with value: ${value}"
  postconf -e "${key} = ${value}"
}

# Read password and username from file to avoid unsecure env variables
if [ -n "${SMTP_PASSWORD_FILE}" ]; then [ -e "${SMTP_PASSWORD_FILE}" ] && SMTP_PASSWORD=$(cat "${SMTP_PASSWORD_FILE}") || echo "SMTP_PASSWORD_FILE defined, but file not existing, skipping."; fi
if [ -n "${SMTP_USERNAME_FILE}" ]; then [ -e "${SMTP_USERNAME_FILE}" ] && SMTP_USERNAME=$(cat "${SMTP_USERNAME_FILE}") || echo "SMTP_USERNAME_FILE defined, but file not existing, skipping."; fi

[ -z "${SMTP_SERVER}" ] && echo "ERROR: SMTP_SERVER is not set" && exit 1
[ -z "${SERVER_HOSTNAME}" ] && echo "ERROR: SERVER_HOSTNAME is not set" && exit 1
[ -n "${SMTP_USERNAME}" ] && [ -z "${SMTP_PASSWORD}" ] && echo "ERROR: SMTP_USERNAME is set but SMTP_PASSWORD is not set" && exit 1

SMTP_PORT="${SMTP_PORT:-587}"

# Get the domain from the server host name
DOMAIN=$(echo "${SERVER_HOSTNAME}" | sed -n 's/[^.]*\.//p')
if [ -z "${DOMAIN}" ]; then
  echo "ERROR: SERVER_HOSTNAME must be a fully qualified name like host.example.com (got '${SERVER_HOSTNAME}')"
  exit 1
fi

# Set needed config options
add_config_value "inet_interfaces" "all"
add_config_value "maillog_file" "/dev/stdout"
add_config_value "myhostname" "${SERVER_HOSTNAME}"
add_config_value "mydomain" "${DOMAIN}"
add_config_value "mydestination" "${DESTINATION:-localhost}"
add_config_value "myorigin" '$mydomain'
add_config_value "relayhost" "[${SMTP_SERVER}]:${SMTP_PORT}"

# TLS towards the relay host. The old "smtp_use_tls = yes" only meant
# opportunistic TLS ("may"): an attacker could strip STARTTLS and the SASL
# password would be sent in clear text. "encrypt" enforces TLS, "secure"
# additionally verifies the server certificate (recommended).
SMTP_TLS_SECURITY_LEVEL="${SMTP_TLS_SECURITY_LEVEL:-encrypt}"
case "${SMTP_TLS_SECURITY_LEVEL}" in
  none|may|encrypt|verify|secure) ;;
  *) echo "ERROR: SMTP_TLS_SECURITY_LEVEL must be one of none, may, encrypt, verify, secure" && exit 1 ;;
esac
if [ "${SMTP_PORT}" = "465" ]; then
  add_config_value "smtp_tls_wrappermode" "yes"
  # Wrapper mode always needs TLS
  case "${SMTP_TLS_SECURITY_LEVEL}" in none|may) SMTP_TLS_SECURITY_LEVEL="encrypt" ;; esac
fi
add_config_value "smtp_tls_security_level" "${SMTP_TLS_SECURITY_LEVEL}"
add_config_value "smtp_tls_CAfile" "/etc/ssl/certs/ca-certificates.crt"

if [ -n "${SMTP_USERNAME}" ]; then
  add_config_value "smtp_sasl_auth_enable" "yes"
  add_config_value "smtp_sasl_password_maps" "lmdb:/etc/postfix/sasl_passwd"
  add_config_value "smtp_sasl_security_options" "noanonymous"
  add_config_value "smtp_sasl_tls_security_options" "noanonymous"
fi
add_config_value "always_add_missing_headers" "${ALWAYS_ADD_MISSING_HEADERS:-no}"
#Also use "native" option to allow looking up hosts added to /etc/hosts via
# docker options (issue #51)
add_config_value "smtp_host_lookup" "native,dns"

# Create sasl_passwd file with auth credentials (unless one was mounted)
if [ -n "${SMTP_USERNAME}" ] && [ ! -f /etc/postfix/sasl_passwd ]; then
  echo "Adding SASL authentication configuration"
  (
    umask 077
    printf '[%s]:%s %s:%s\n' "${SMTP_SERVER}" "${SMTP_PORT}" "${SMTP_USERNAME}" "${SMTP_PASSWORD}" > /etc/postfix/sasl_passwd
  )
fi
if [ -f /etc/postfix/sasl_passwd ]; then
  postmap /etc/postfix/sasl_passwd
  chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.lmdb
fi

# Header checks (several features may need them, so collect them in a list)
header_checks=""

#Set header tag
if [ -n "${SMTP_HEADER_TAG}" ]; then
  printf '/^MIME-Version:/i PREPEND RelayTag: %s\n/^Content-Transfer-Encoding:/i PREPEND RelayTag: %s\n' \
    "${SMTP_HEADER_TAG}" "${SMTP_HEADER_TAG}" > /etc/postfix/header_tag
  header_checks="regexp:/etc/postfix/header_tag"
  echo "Setting configuration option SMTP_HEADER_TAG with value: ${SMTP_HEADER_TAG}"
fi

#Enable logging of subject line
if [ "${LOG_SUBJECT}" == "yes" ]; then
  printf '/^Subject:/ WARN\n' > /etc/postfix/header_checks
  header_checks="${header_checks:+${header_checks}, }regexp:/etc/postfix/header_checks"
  echo "Enabling logging of subject line"
fi

if [ -n "${header_checks}" ]; then
  add_config_value "header_checks" "${header_checks}"
else
  postconf -X header_checks
fi

#Check for subnet restrictions
# By default all private IPv4 networks may relay. Set SMTP_NETWORKS_ONLY=yes
# to allow only localhost and the networks given in SMTP_NETWORKS.
nets='127.0.0.0/8, [::1]/128'
if [ "${SMTP_NETWORKS_ONLY}" != "yes" ]; then
  nets+=', 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16'
fi
if [ -n "${SMTP_NETWORKS}" ]; then
  for i in ${SMTP_NETWORKS//,/ }; do
    if grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' <<<"$i"; then
      nets+=", $i"
    elif grep -Eq '^\[?[0-9a-fA-F:]+\]?/[0-9]{1,3}$' <<<"$i" && [[ "$i" == *:* ]]; then
      # IPv6: postfix wants [addr]/len
      addr=${i%/*}; addr=${addr#\[}; addr=${addr%\]}
      nets+=", [${addr}]/${i##*/}"
    else
      echo "$i is not in proper IPv4 or IPv6 subnet format. Ignoring."
    fi
  done
fi
add_config_value "mynetworks" "${nets}"

# Set SMTPUTF8
if [ -n "${SMTPUTF8_ENABLE}" ]; then
  add_config_value "smtputf8_enable" "${SMTPUTF8_ENABLE}"
fi

if [ -n "${OVERWRITE_FROM}" ]; then
  printf '/^From:.*$/ REPLACE From: %s\n' "${OVERWRITE_FROM}" > /etc/postfix/smtp_header_checks
  add_config_value "smtp_header_checks" "regexp:/etc/postfix/smtp_header_checks"
fi

if [ -n "${OVERWRITE_SENDER}" ]; then
  # shellcheck disable=SC2016 # ${1} is a postfix regexp back-reference
  printf '/^(.*@).*$/    ${1}%s\n' "${OVERWRITE_SENDER}" > /etc/postfix/sender_canonical
  add_config_value "sender_canonical_maps" "regexp:/etc/postfix/sender_canonical"
fi

# Set message_size_limit
if [ -n "${MESSAGE_SIZE_LIMIT}" ]; then
  add_config_value "message_size_limit" "${MESSAGE_SIZE_LIMIT}"
fi

#Start services

# If host mounting /var/spool/postfix, we need to delete old pid file before
# starting services
rm -f /var/spool/postfix/pid/master.pid

exec /usr/sbin/postfix -c /etc/postfix start-fg
