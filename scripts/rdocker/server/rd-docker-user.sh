#!/bin/bash
# rd-docker-user: DOCKER-USER chain = the one place Docker lets us filter published/forwarded traffic.
# Allow loopback, Tailscale, the docker bridges and established replies; DROP everything else that arrives
# on a physical interface. Rebuilt from scratch on every run (idempotent); run by rd-docker-user.service.
set -u
IPT="${RD_IPTABLES:-iptables}"
"$IPT" -N DOCKER-USER 2>/dev/null
"$IPT" -F DOCKER-USER
"$IPT" -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
for i in lo tailscale0 'docker+' 'br-+'; do "$IPT" -A DOCKER-USER -i "$i" -j RETURN; done
"$IPT" -A DOCKER-USER -j DROP
