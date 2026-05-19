
[[ -f /etc/sysctl.d/90-net.conf ]] && exit 0

PUB_IF=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+')

# IPV6=$(ip -6 addr show dev "$PUB_IF" scope global | grep -q "inet6")

cat <<EOF >/etc/sysctl.d/90-net.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.${PUB_IF}.rp_filter = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.${PUB_IF}.accept_ra = 2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system
