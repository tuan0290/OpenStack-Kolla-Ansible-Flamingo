#!/bin/bash

echo "=== Kolla-Ansible container started ==="
echo "Kolla-Ansible version: $(kolla-ansible --version)"
echo "Ansible version: $(ansible --version | head -1)"
echo ""
echo "Config: /etc/kolla/globals.yml"
echo "Inventory: /kolla/inventory/multinode"
echo ""

tail -f /dev/null
