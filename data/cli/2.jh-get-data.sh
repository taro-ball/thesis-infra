#!/usr/bin/bash
source metrics_vars.txt
echo -e "$t_start..$t_end\n$asg_name\n$lb_name"

envsubst < alb-query-template.json > alb-query.json
envsubst < asg-query-template.json > asg-query.json

# get CloudWatch metrics
aws cloudwatch get-metric-data --cli-input-json file://alb-query.json --region us-east-1 > alb_data.json
aws cloudwatch get-metric-data --cli-input-json file://asg-query.json --region us-east-1 > asg_data.json

ls -1sh *data.json