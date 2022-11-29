#!/bin/sh

export RELEASE_DISTRIBUTION="name"
export RELEASE_NAME="mc714_p2"
export RELEASE_COOKIE="mc714-p2"
export RELEASE_NODE="${RELEASE_NAME}@${POD_IP}"

export HOST=$(hostname --fqdn)
export PAXOS_NODE=$HOST
export PAXOS_ROOT=mc714-p2-0

exec /app/bin/mc714_p2 $@
