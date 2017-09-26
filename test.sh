#!/bin/bash
#
# Ansible role test shim.
#
# Usage: [OPTIONS] ./tests/test.sh
#   - distribution: a supported Docker distribution name (default = "debian")
#   - version: a associated Docker distribution version (default = "stretch")
#   - playbook: a playbook in the tests directory (default = "playbook.yml")
#   - cleanup: whether to remove the Docker container (default = true)
#   - container_id: the --name to set for the container (default = timestamp)
#   - test_idempotence: whether to test playbook's idempotence (default = true)

# Exit on any individual command failure.
set -e

# Pretty colors.
red='\033[0;31m'
green='\033[0;32m'
neutral='\033[0m'

action=$1
timestamp=$(date +%s)

# Allow environment variables to override defaults.
distribution=${distribution:-"debian"}
version=${version:-"stretch"}
playbook=${playbook:-"test.yml"}
cleanup=${cleanup:-"true"}
container_id=${container_id:-$timestamp}
test_idempotence=${test_idempotence:-"true"}

# Debian 9
if [ "${distribution}/${version}" = "debian/9" ]; then
  init="/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
# Ubuntu 16.04
elif [ "${distribution}/${version}" = "ubuntu/16.04" ]; then
  init="/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
# CentOS 7
elif [ "${distribution}/${version}" = "centos/7" ]; then
  init="/usr/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
fi

build()
{
  # Download Docker file for the supplied OS.
  wget -O ${PWD}/tests/Dockerfile https://raw.githubusercontent.com/ontic/ansible-role-test/master/docker/Dockerfile.${distribution}-${version}
  
  # Build and run the container using the supplied OS.
  printf ${green}"Starting Docker container: ${distribution}/${version}"${neutral}"\n"
  docker pull ${distribution}:${version}
  docker build --rm=true --file=tests/Dockerfile --tag=${distribution}-${version}:ansible tests
  docker run --detach --volume=${PWD}:/etc/ansible/roles/role_under_test:rw --name $container_id $opts ${distribution}-${version}:ansible $init
  
  if [ $distribution = "debian" ] || [ $distribution = "ubuntu" ]; then
    docker exec --tty $container_id env TERM=xterm apt-get update
  fi
}

test()
{
  # Install requirements if `requirements.yml` is present.
  if [ -f "$PWD/tests/requirements.yml" ]; then
    printf ${green}"Installing Ansible role dependencies."${neutral}"\n"
    docker exec --tty $container_id env TERM=xterm ansible-galaxy install -r /etc/ansible/roles/role_under_test/tests/requirements.yml
  fi
  
  printf "\n"
  
  # Test Ansible syntax.
  printf ${green}"Checking Ansible playbook syntax."${neutral}
  docker exec --tty $container_id env TERM=xterm ansible-playbook /etc/ansible/roles/role_under_test/tests/$playbook --syntax-check
  
  printf "\n"
  
  # Run Ansible playbook.
  printf ${green}"Running Ansible playbook: docker exec $container_id env TERM=xterm ansible-playbook /etc/ansible/roles/role_under_test/tests/$playbook"${neutral}
  docker exec $container_id env TERM=xterm env ANSIBLE_FORCE_COLOR=1 ansible-playbook /etc/ansible/roles/role_under_test/tests/$playbook
  
  if [ "$test_idempotence" = true ]; then
    # Run Ansible playbook again (idempotence test).
    printf ${green}"Running Ansible playbook again: testing idempotency"${neutral}
    idempotence=$(mktemp)
    docker exec $container_id ansible-playbook /etc/ansible/roles/role_under_test/tests/$playbook | tee -a $idempotence
    tail $idempotence \
      | grep -q 'changed=0.*failed=0' \
      && (printf ${green}'Idempotence test: pass'${neutral}"\n") \
      || (printf ${red}'Idempotence test: fail'${neutral}"\n" && exit 1)
  fi
  
  # Remove the Docker container (if configured).
  if [ "$cleanup" = true ]; then
    printf "Removing Docker container...\n"
    docker rm -f $container_id
  fi
}

eval ${action}