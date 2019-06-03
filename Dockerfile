FROM alpine:3.9.4

RUN apk add --no-cache openssh python3 socat && \
    ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa >/dev/null 2>&1 && \
    ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa >/dev/null 2>&1 && \
    ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519 >/dev/null 2>&1

EXPOSE 32233

CMD NAMESERVER=$(awk '/^nameserver/{print $2}' /etc/resolv.conf) && \
    echo "Found nameserver $NAMESERVER" && \
    echo "Starting DNS proxy..." && \
    # proxy DNS traffic from tcp:localhost:5353 to the nameserver
    socat tcp4-listen:5353,reuseaddr,fork "udp:$NAMESERVER:53" & \
    # quit on signal
    trap "exit" INT TERM && \
    # passwd -d root >/dev/null 2>&1
    echo "root:${ROOT_PASSWORD:-root}" | chpasswd >/dev/null 2>&1 && \
    # ssh key -> authorixed_hosts, if defined
    mkdir -p /root/.ssh && \
    AUTHORIZED_KEY="${AUTHORIZED_KEY:-ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCN5itZkAcZBzxV3a5JiU+DjMJIl+hX5or1Q57AxY6bd3a/gOr9JUTVqVSmKkLDX4cpYW6k4SN2b9+xSkBTNSNA=}" && \
    echo "$AUTHORIZED_KEY" >> /root/.ssh/authorized_keys && \
    echo "Starting ssh server..." && \
    /usr/sbin/sshd -p 32233 -D \
    -o "PermitRootLogin yes" \
    -o "GatewayPorts yes" \
    -o "AllowTcpForwarding yes" \
    -o "AllowStreamLocalForwarding yes" \
    -o "PermitTunnel yes" \
    -o "ClientAliveInterval 1" \
    -o "ClientAliveCountMax 2"