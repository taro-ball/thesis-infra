#!/bin/bash

autotest=$1
match=`cat data/cli/0.setup.sh | grep -ho $1 2> /dev/null`

if [ -z "$match" ]; then
    echo Test name not recognized. Valid options:
    egrep -ho 'asg_\w+|k8s_\w+' data/cli/0.setup.sh
    exit 1
fi

set -x

# if not using default profile
# source .exclAuthenticate.sh # cant use until k8s creds are properly fixed
aws sts get-caller-identity


# write new key only if successful
pem=$(aws ec2 create-key-pair --key-name dev-key) && echo "$pem" | jq --raw-output '.KeyMaterial' > .exclDEV-Key.pem

cd aws-tools
./deployJumpHost.sh 1 $autotest
cd ..

if  [ "${autotest:0:3}" != "k8s" ]; then
    cd aws-asg
    ./deployASG.sh 1 $autotest
    cd ..
fi

if  [ "${autotest:0:3}" != "asg" ]; then
    eksctl create cluster -f eksctl/Cgenerated.yml
    cd k8s
    ./apply-k8s.sh $autotest
    cd ..
fi
