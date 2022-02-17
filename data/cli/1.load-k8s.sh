#!/usr/bin/bash
set -x

app="apache3"
echo export t_start=$(date +%FT%T) >> dates.txt
export AWS_DEFAULT_REGION=us-east-1

if [ "$app" == "apache3" ]; then
warmup_url='80/test.html'
testing_url='80/test.html'
cpu_perc=70
warmup_min_threads=65
warmup_max_threads=75
warmup_cycle_sec=120
scaling_sec=800
max_capacity=3
fi

if [ "$app" == "node4k8s" ]; then
warmup_url='3000?n=5555'
testing_url='3000?n=9999'
hpa_perc=70
warmup_min_threads=15
warmup_max_threads=25
warmup_cycle_sec=60
scaling_sec=750
max_pods=8
fi

# authenticate
source .k8sSecrets
# log on to k8s
aws eks update-kubeconfig --region us-east-1 --name C888 

# get lb
lb=`kubectl get svc/taro-svc -o json | jq --raw-output '.status.loadBalancer.ingress[0].hostname'`

# set max, scale to max
echo scaling to $max_capacity;
kubectl delete horizontalpodautoscaler.autoscaling/taro-deployment;
kubectl scale --replicas=8 deployment/taro-deployment

# remember to enable metrics
myasg=`aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*].AutoScalingGroupName' --output text| sed 's/\s\+/\n/g' | grep workers`
aws autoscaling enable-metrics-collection --auto-scaling-group-name $myasg --granularity "1Minute"

# quick test
pwd; curl http://$lb:$warmup_url; echo

# LB warmup
for((i=$warmup_min_threads;i<=$warmup_max_threads;i+=1)); do fortio load -a -c $i -t ${warmup_cycle_sec}s -qps -1 -r 0.01 -labels "$app-warmup" http://$lb:$warmup_url; sleep 60 ; done

# performance
for((i=1;i<=3;i+=1)); do sleep 60; fortio load -a -c $warmup_max_threads -t 30s -qps -1 -r 0.01 -labels "$app-performance-${i}" http://$lb:$testing_url; done

echo export t_scaling=$(date +%FT%T) >> dates.txt
# scaling
for((i=1;i<=3;i+=1));
do

    # delete hpa to prevent immideate scaleout on historical data
    kubectl delete horizontalpodautoscaler.autoscaling/taro-deployment

	# scale to min
    echo scaling to 1;
    kubectl scale --replicas=1 deployment/taro-deployment
    
    sleep 180;
        # create the hpa
        kubectl autoscale deployment taro-deployment --cpu-percent=50 --min=1 --max=8

    fortio load -a -c $warmup_max_threads -t ${scaling_sec}s -qps -1 -r 0.01 -labels "$app-scaling-${i}" http://$lb:$testing_url
done
# note
# date -d "+ 10 minutes" +%FT%T
echo export t_end=$(date +%FT%T) >> dates.txt

# wait for CloudWatch logs to catch up
sleep 600
./2.jh-get-data.sh
./3.upload.sh