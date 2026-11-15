#!/bin/bash
# First boot of the bc-code-atlas VM: clone the repository and hand over to
# setup-vm.sh. main.bicep fills in the __PLACEHOLDERS__. Log: /var/log/bcatlas-setup.log
set -euxo pipefail
exec > >(tee -a /var/log/bcatlas-setup.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git

id bcatlas >/dev/null 2>&1 || useradd --create-home --shell /bin/bash bcatlas
install -d -o bcatlas -g bcatlas /opt/bcatlas
if [ ! -d /opt/bcatlas/bc-code-atlas/.git ]; then
  sudo -u bcatlas -H git clone --branch '__REPO_BRANCH__' '__REPO_URL__' /opt/bcatlas/bc-code-atlas
fi
bash /opt/bcatlas/bc-code-atlas/deploy/navipro/setup-vm.sh '__HOSTNAME__' '__GITHUB_ORGS__' '__SCALE_DOWN_TO__'
