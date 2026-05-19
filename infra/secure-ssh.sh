set -e


useradd -MNs /usr/sbin/nologin -g 65534 -c "bastion" ${SSH_USER:-bastion}

if [[ -z "${SSH_PASSWORD:-}" ]]; then
    read -rsp "Enter password for ${SSH_USER:-bastion}: " SSH_PASSWORD
    echo
fi

echo "${SSH_USER:-bastion}:$SSH_PASSWORD" | chpasswd

ln /root/.ssh/authorized_keys /root/.ssh/bastion_authorized_keys

cat <<EOF > /etc/ssh/sshd_config.d/99-ssh-hardening.conf
Port ${SSH_PORT:-2222}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes

AllowUsers ${SSH_USER:-bastion} root

Match User ${SSH_USER:-bastion}
    AuthorizedKeysFile /root/.ssh/bastion_authorized_keys
    PasswordAuthentication yes
    PubkeyAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding yes

Match User root Address 127.0.0.1,::1
    PermitRootLogin yes
    PasswordAuthentication no
    PubkeyAuthentication yes
EOF

sshd -t && systemctl restart sshd

echo "ssh -p ${SSH_PORT:-2222} -J ${SSH_USER:-bastion}@$(curl -4s http://ifconfig.me):${SSH_PORT:-2222} root@localhost"