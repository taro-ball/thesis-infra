#!/usr/bin/bash
aws cloudformation create-stack\
 --disable-rollback --capabilities CAPABILITY_NAMED_IAM CAPABILITY_IAM CAPABILITY_AUTO_EXPAND\
 --stack-name $2\
 --template-body file://asg-template.yaml --parameters file://$1
 