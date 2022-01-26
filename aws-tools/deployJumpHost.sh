#!/usr/bin/bash
aws sts get-caller-identity
vpcID=`aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[*].VpcId' \
    --output text`

# if CloudFormation errors with no available t3.medium instances 
# then pick any except A and B
# Usually 2-5, but can check with:
# aws ec2 describe-subnets --filters "Name=vpc-id,Values=${vpcID}"  --output text --query 'Subnets[*].[AvailabilityZone,SubnetId]'

sbntID=`aws ec2 describe-subnets --filters "Name=vpc-id,Values=${vpcID}"  --output text --query 'Subnets[2].SubnetId'`

set -x

aws cloudformation create-stack\
 --disable-rollback --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM CAPABILITY_AUTO_EXPAND\
 --stack-name jumphost-$1 --template-body file://jumphost.yaml\
 --parameters ParameterKey=myVPC,ParameterValue=${vpcID} ParameterKey=mySubnet1,ParameterValue=${sbntID}

