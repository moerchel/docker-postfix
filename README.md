# docker-postfix

Forked from [juanluisbaptiste/docker-postfix](https://github.com/juanluisbaptiste/docker-postfix)

---

Simple Postfix SMTP TLS relay [docker](https://www.docker.com) alpine based image with no local authentication enabled (to be run in a secure LAN).

This image is available for the following architectures:

* amd64
* arm64
* armv7

## Available image tags

Images are published on [GitHub Container Registry](https://github.com/moerchel/docker-postfix/pkgs/container/docker-postfix):

* _latest_ / _main_: current state of the `main` branch.
* _YYYYMMDD_: releases (git tags like `20260416`) and the weekly automatic rebuilds that pick up Alpine security updates.
* _sha-xxxxxxx_: the image built from a specific commit.

Every image is scanned with [Trivy](https://github.com/aquasecurity/trivy) before it is published. Builds with fixable HIGH or CRITICAL vulnerabilities are not published, all findings are listed in the repository's [Security tab](https://github.com/moerchel/docker-postfix/security/code-scanning).

## Build instructions

Clone this repo and then:

    cd docker-postfix
    docker build -t moerchel/docker-postfix .

Or pull the prebuilt image:

    docker pull ghcr.io/moerchel/docker-postfix:latest

## How to run it

The following env variables need to be passed to the container:

* `SMTP_SERVER` Server address of the SMTP server to use.
* `SMTP_PORT` (Optional, Default value: 587) Port of the SMTP server to use. Port 465 automatically uses implicit TLS (wrapper mode).
* `SMTP_USERNAME` (Optional) Username to authenticate with.
* `SMTP_PASSWORD` (Mandatory if `SMTP_USERNAME` is set) Password of the SMTP user. If `SMTP_PASSWORD_FILE` is set, not needed.
* `SERVER_HOSTNAME` Fully qualified hostname for the Postfix container (e.g. `relay.example.com`). Emails will appear to come from the hostname's domain.

The following env variable(s) are optional.

* `SMTP_TLS_SECURITY_LEVEL` TLS policy towards `SMTP_SERVER` (default: `encrypt`). Valid values: `none`, `may`, `encrypt`, `verify`, `secure`.
  * `encrypt` enforces TLS, so the password can never be sent in clear text.
  * `secure` additionally verifies the server certificate against the hostname in `SMTP_SERVER`. This is **recommended** for public mail providers.
  * Use `may` (old behaviour, opportunistic TLS) only for internal relays without TLS.

  See [smtp_tls_security_level](https://www.postfix.org/postconf.5.html#smtp_tls_security_level).

* `SMTP_HEADER_TAG` This will add a header for tracking messages upstream. Helpful for spam filters. Will appear as "RelayTag: ${SMTP_HEADER_TAG}" in the email headers.

* `SMTP_NETWORKS` Setting this will allow you to add additional, comma separated, IPv4 or IPv6 subnets to use the relay. Used like:

  ```
  -e SMTP_NETWORKS='192.168.10.0/24,2001:db8::/32'
  ```

* `SMTP_NETWORKS_ONLY` By default localhost and **all** private IPv4 networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) may relay. Set this to `yes` to allow only localhost and the networks from `SMTP_NETWORKS`.

* `SMTP_PASSWORD_FILE` Setting this to a mounted file containing the password, to avoid passwords in env variables. Used like:

  ```
  -e SMTP_PASSWORD_FILE=/secrets/smtp_password
  -v $(pwd)/secrets/:/secrets/:ro
  ```

* `SMTP_USERNAME_FILE` Setting this to a mounted file containing the username, to avoid usernames in env variables. Used like:

  ```
  -e SMTP_USERNAME_FILE=/secrets/smtp_username
  -v $(pwd)/secrets/:/secrets/:ro
  ```

* `ALWAYS_ADD_MISSING_HEADERS` This is related to the [always\_add\_missing\_headers](https://www.postfix.org/postconf.5.html#always_add_missing_headers) Postfix option (default: `no`). If set to `yes`, Postfix will always add missing headers among `From:`, `To:`, `Date:` or `Message-ID:`.

* `OVERWRITE_FROM` This will rewrite the from address overwriting it with the specified address for all email being relayed. Example settings:

  ```
  OVERWRITE_FROM=email@company.com
  OVERWRITE_FROM="Your Name" <email@company.com>
  ```

* `OVERWRITE_FROM_KEEP_NAME` Set to `yes` to replace only the address in the `From:` header and keep the original sender as display name, so you can still see which machine sent the mail:

  ```
  From: root@server1                  ->  From: "root@server1" <email@company.com>
  From: "Backup Job" <backup@nas>     ->  From: "Backup Job" <email@company.com>
  From: root@server1 (Cron Daemon)    ->  From: "Cron Daemon (root@server1)" <email@company.com>
  ```

* `OVERWRITE_SENDER` This will rewrite the envelope sender address (`MAIL FROM`, used for bounces) for all email being relayed. A domain replaces only the domain, a full address replaces the whole address. Example settings:

  ```
  OVERWRITE_SENDER=company.com          # username@home.net -> username@company.com
  OVERWRITE_SENDER=relay@company.com    # username@home.net -> relay@company.com
  ```

* `SMTPD_TLS` Set to `yes` to offer STARTTLS to the clients in the LAN. TLS is optional, clients using plain SMTP keep working. Without own certificate a self-signed certificate for `SERVER_HOSTNAME` is generated on the first start.

* `SMTPD_TLS_CERT_FILE` / `SMTPD_TLS_KEY_FILE` (Optional, only with `SMTPD_TLS=yes`) Mounted certificate (PEM, may contain the chain) and key to use instead of the self-signed one, e.g. `/secrets/relay.crt` and `/secrets/relay.key`.

* `DESTINATION` This will define a list of domains from which incoming messages will be accepted.

* `LOG_SUBJECT` Set to `yes` to output the subject line of messages in the log.

* `SMTPUTF8_ENABLE` This will enable (default) or disable support for SMTPUTF8. Valid values are `no` to disable and `yes` to enable. Not setting this variable will use the postfix default, which is `yes`.

* `MESSAGE_SIZE_LIMIT` This will change the default limit of 10240000 bytes (10MB).

* `DEBUG` Set to `yes` for a verbose output of the start script.

### Sender addresses

Most mail providers only accept mail whose sender matches the account used for authentication. Servers and devices in the LAN often send as `root@server1` or `printer@localdomain`, which the provider will reject. Rewrite both addresses to your account and keep the original sender visible:

    SMTP_USERNAME=relay@company.com
    OVERWRITE_SENDER=relay@company.com
    OVERWRITE_FROM=relay@company.com
    OVERWRITE_FROM_KEEP_NAME=yes

### Security note: don't become an open relay

The relay accepts mail from every address in the allowed networks without authentication. Only publish port 25 on an address that is reachable from your LAN, never on a public interface:

    -p 192.168.1.10:25:25     # LAN address of the docker host
    -p 127.0.0.1:2525:25      # only local clients

Depending on the docker setup (userland proxy, rootless docker, IPv6) connections from outside can reach the container with the docker gateway address (e.g. `172.17.0.1`), which is part of the default private networks. If in doubt, use `SMTP_NETWORKS_ONLY=yes` together with `SMTP_NETWORKS`.

### Examples

To use this container from other hosts in your LAN, publish port 25 on the LAN address of the docker host:

    docker run -d --name postfix -p "192.168.1.10:25:25" \
           -e SMTP_SERVER=smtp.bar.com \
           -e SMTP_USERNAME=foo@bar.com \
           -e SMTP_PASSWORD=XXXXXXXX \
           -e SMTP_TLS_SECURITY_LEVEL=secure \
           -e SERVER_HOSTNAME=helpdesk.mycompany.com \
           ghcr.io/moerchel/docker-postfix:latest

If you are going to use this container only from other docker containers, don't publish the port at all and put the containers into the same docker network:

    docker network create mail
    docker run -d --name postfix --network mail \
           -e SMTP_SERVER=smtp.bar.com \
           -e SMTP_USERNAME=foo@bar.com \
           -e SMTP_PASSWORD=XXXXXXXX \
           -e SERVER_HOSTNAME=helpdesk.mycompany.com \
           ghcr.io/moerchel/docker-postfix:latest

The other containers then use `postfix:25` as SMTP server.

### docker compose

Use the provided [docker-compose](docker-compose/docker-compose.yml) setup for production use:

    cd docker-compose
    cp .env.example .env          # and edit .env
    docker compose up -d

All variables in `.env` are passed to the container. By default the port is only published on `127.0.0.1:2525`; set `POSTFIX_BIND_ADDRESS` (and `POSTFIX_HOST_PORT`) in `.env` to make the relay reachable from your LAN.

To see the email logs in real time:

    docker logs -f postfix

To send a test mail from inside the container:

    docker exec -it postfix sh -c 'echo "Test" | mail -s "Test" you@example.com'

#### A note about using gmail as a relay

Gmail requires an [app password](https://support.google.com/accounts/answer/185833) (2-step verification must be enabled) for SMTP authentication. Use `smtp.gmail.com`, port 587 and the app password as `SMTP_PASSWORD`.

Also take into account that email `From:` header will contain the email address of the account being used to
authenticate against the Gmail SMTP server (SMTP_USERNAME), the one on the email will be ignored by Gmail unless you [add it as an alias](https://support.google.com/mail/answer/22370).

### Debugging

If you need troubleshooting the container you can set the environment variable _DEBUG=yes_ for a more verbose output.
