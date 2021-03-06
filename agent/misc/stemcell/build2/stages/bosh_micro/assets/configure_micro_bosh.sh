#!/bin/bash
#
# Copyright (c) 2009-2012 VMware, Inc.

bosh_src_dir=/var/vcap/bosh/src/micro_bosh
bosh_app_dir=/var/vcap
blobstore_path=${bosh_app_dir}/micro_bosh/data/cache
agent_uri=http://vcap:vcap@localhost:6969

export PATH=${bosh_app_dir}/bosh/bin:$PATH
export HOME=/root

(
  cd ${bosh_src_dir}/package_compiler
  chmod +x bin/package_compiler
  mkdir -p ${bosh_src_dir}/bosh/gems
  bundle install --path ${bosh_src_dir}/bosh/gems
)

mkdir -p ${bosh_app_dir}/bosh/blob
mkdir -p ${blobstore_path}

echo "Starting micro bosh compilation"

# Start agent
/var/vcap/bosh/agent/bin/agent -n ${agent_uri} -s ${blobstore_path} -p local &
agent_pid=$!
echo "Starting BOSH Agent for compiling micro bosh package, agent pid is $agent_pid"

# Start compiler
/var/vcap/bosh/bin/ruby ${bosh_src_dir}/package_compiler/bin/package_compiler compile ${bosh_src_dir}/release.yml ${bosh_src_dir}/release.tgz ${blobstore_path} ${agent_uri}

function kill_agent {
  signal=$1
  kill -$signal $agent_pid > /dev/null 2>&1
}

kill_agent 15
# Wait for agent
for i in {1..5}
do
  kill_agent 0 && break
  sleep 1
done
# Force kill if required
kill_agent 0 || kill_agent 9

# Clean out src
cd /var/tmp
rm -fr ${bosh_app_dir}/bosh/src
