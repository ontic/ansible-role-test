#!/bin/bash
#
# Copyright (c) Ontic. (http://www.ontic.com.au). All rights reserved.
# See the COPYING file bundled with this package for license details.
#
# Ansible role test runner.
#
# Usage: [OPTIONS] ./tests/docker.sh [ action = ( build | test | verify ) ]
#   - distribution: a supported Docker distribution name (default = "debian")
#   - version: a associated Docker distribution version (default = "stretch")
#   - playbook: a playbook in the tests directory (default = "test.yml")
#   - cleanup: whether to remove the Docker container (default = true)
#   - container_id: the --name to set for the container (default = timestamp)
#   - test_idempotence: whether to test a playbook idempotence (default = true)
#   - base_url: the base url for downloading Docker files (default = https://raw.githubusercontent.com/ontic/ansible-role-test/master/docker)

# Exit on any individual command failure.
set -e

# Terminal colors.
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
purple='\033[1;35m'
heading='\033[1;32m'
neutral='\033[0m'

if [ "${1}" != "build" ] && [ "${1}" != "test" ] && [ "${1}" != "verify" ]; then
  printf "${red}Expected a supplied action of 'build', 'test' or 'verify'${neutral}\n"
  exit 1
fi

# First argument used to execute an action.
action="${1}_action"
# Timestamp used as the default container ID.
timestamp=$(date +%s)

# Override default values with environment variables.
distribution=${distribution:-"debian"}
version=${version:-"stretch"}
folder=${folder:-"tests"}
playbook=${playbook:-"test.yml"}
requirements=${requirements:-"requirements.yml"}
cleanup=${cleanup:-"true"}
container_id=${container_id:-$timestamp}
test_idempotence=${test_idempotence:-"true"}
base_url=${base_url:-"https://raw.githubusercontent.com/ontic/ansible-role-test/master/docker"}

# Set variables for each operating system which configure the container.
if [ "${distribution}/${version}" = "debian/9" ]; then
  init="/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
elif [ "${distribution}/${version}" = "ubuntu/16.04" ]; then
  init="/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
elif [ "${distribution}/${version}" = "centos/7" ]; then
  init="/usr/lib/systemd/systemd"
  opts="--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro"
fi

# Build the container
build_action()
{
  # Download Docker file for the supplied distribution and version.
  wget -O "${PWD}/tests/Dockerfile" "${base_url}/Dockerfile.${distribution}-${version}"
  
  # Build and run the container using the supplied distribution and version.
  printf "${heading}Starting Docker container: ${distribution}/${version}${neutral}\n"
  docker pull "${distribution}:${version}"
  docker build --rm=true --file=tests/Dockerfile --tag="${distribution}-${version}:ansible" tests
  docker run --detach --volume="${PWD}:/etc/ansible/roles/role_under_test:rw" --name="${container_id}" ${opts} "${distribution}-${version}:ansible" ${init}
  
  # If the distribution is either Debian or Ubuntu.
  if [ "${distribution}" = "debian" ] || [ "${distribution}" = "ubuntu" ]; then
    # Update the repository cache so not required by playbooks.
    docker exec --tty ${container_id} env TERM=xterm apt-get update
  fi
}

# Test the role
test_action()
{
  # If a requirements file exists.
  if [ -f "${PWD}/${folder}/${requirements}" ]; then
    # Install roles dependencies using Ansible Galaxy.
    printf "\n${heading}Installing Ansible role dependencies.${neutral}\n"
    docker exec --tty ${container_id} env TERM=xterm cd /etc/ansible/roles/role_under_test && ansible-galaxy install -r ${folder}/${requirements}
  elif [ -f "${PWD}/${requirements}" ]; then
    # Install roles dependencies using Ansible Galaxy.
    printf "\n${heading}Installing Ansible role dependencies.${neutral}\n"
    docker exec --tty ${container_id} env TERM=xterm cd /etc/ansible/roles/role_under_test && ansible-galaxy install -r ${requirements}
  fi
  
  # Test playbook syntax.
  printf "\n${heading}Checking Ansible playbook syntax.${neutral}\n"
  docker exec --tty ${container_id} env TERM=xterm cd /etc/ansible/roles/role_under_test && ansible-playbook ${folder}/${playbook} --syntax-check
  
  # Run the playbook.
  printf "\n${heading}Running Ansible playbook.${neutral}\n"
  docker exec ${container_id} env TERM=xterm env ANSIBLE_FORCE_COLOR=1 cd /etc/ansible/roles/role_under_test && ansible-playbook ${folder}/${playbook}
  
  # If testing for idempotence is configured.
  if [ "${test_idempotence}" = true ]; then
    # Create a temporary file for storing output.
    idempotence=$(mktemp)
    # Run the playbook again and record the output.
    printf "\n${heading}Testing Ansible playbook idempotence.${neutral}\n"
    docker exec ${container_id} cd /etc/ansible/roles/role_under_test && ansible-playbook ${folder}/${playbook} | tee -a ${idempotence}
    tail ${idempotence} | grep -q 'changed=0.*failed=0' \
      && (printf ${green}"Idempotence test: [pass]"${neutral}) \
      || (printf ${red}"Idempotence test: [fail]"${neutral} && exit 1)
  fi
  
  # If removing the container is configured.
  if [ "${cleanup}" = true ]; then
    # Remove the container.
    printf "\n${heading}Removing Docker container.${neutral}\n"
    docker rm -f ${container_id}
  fi
}

# Verify the system
verify_action()
{
  # If a test-verify.sh file exists.
  if [ -f "${PWD}/tests/test-verify.sh" ]; then
    # Ensure the file is executable then execute it.
    printf "\n${purple}Verifying system details.${neutral}\n\n"
    chmod +x ${PWD}/tests/test-verify.sh
    ${PWD}/tests/test-verify.sh
  fi
}

# Invoke the supplied action. 
eval ${action}