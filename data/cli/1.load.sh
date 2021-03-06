#!/usr/bin/bash
set -x
mydir=`dirname "$0"`
cd $mydir
test=$(cat mytest)
type=$(cut -d "_" -f 1 <<< $test)
exec >> load-${type}.log
exec 2>&1
# exec 2> load-errors.log # also sends all fortio output to err log
git log -3
app=$(cut -d "_" -f 2 <<< $test)
export AWS_DEFAULT_REGION="us-east-1"
line='=============================='

echo [$(date +%FT%T)]${line}[starting in $PWD]${line}

source 0.setup.sh
source .k8sSecrets.noupl
aws sts get-caller-identity
#port=`echo $string1 | sed -r 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/'`

############# Functions #############
check_stats () {
  echo [$(date +%FT%T)]${line}[STATS]
  echo jh CPU load avg:
  cat /proc/loadavg
  if [ "$1" == "asg" ]; then
    aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*]' | \
    jq --raw-output '.[]| .Instances[] | (.InstanceId, .LifecycleState, .HealthStatus, {})'
  fi
  if [ "$1" == "k8s" ]; then
    kubectl get hpa
    kubectl get deployment
    kubectl top nodes 2> /dev/null
    #make sure all nodes have monitoring on
    aws ec2 monitor-instances --instance-ids `aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*].Instances[*].InstanceId' --output text` --output text | grep enabled # > /dev/null
  fi
}

############# Ready check #############
while [ -z "$mycheck" ]
do 
  if [ "$type" == "asg" ]; then
    mycheck=`aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*].AutoScalingGroupName' --output text | sed 's/\s\+/\n/g' | grep myASG`
  fi
  if [ "$type" == "k8s" ]; then
    mycheck=`aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*].AutoScalingGroupName' --output text | sed 's/\s\+/\n/g' | grep workers`
    
  fi
  echo [$(date +%FT%T)] waiting for instances ...
  sleep 60;
done


echo export t_start=$(date +%FT%T) >> metrics_vars.txt
myasg=`aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[*].AutoScalingGroupName' --output text`

if [ "$type" == "k8s" ]; then
  # enable advanced ec2 metrics in the lt (have to apply new ver in console mannually)
  template_name=`aws ec2 describe-launch-templates --query 'LaunchTemplates[*].LaunchTemplateName' --output text | sed 's/\s\+/\n/g' | grep eks-`
  aws ec2 create-launch-template-version  --launch-template-name ${template_name} --version-description EnableAdvMonitoring --source-version 1 --launch-template-data '{"Monitoring": {"Enabled": true}}'
  aws ec2 modify-launch-template --launch-template-name ${template_name} --default-version 2
  # aws autoscaling update-auto-scaling-group \ #(disabled auto apply as it doesn't seem to work, see 6 March notes)
  #   --auto-scaling-group-name $myasg \
  #   --launch-template LaunchTemplateName=${template_name},Version='$Latest'
  ## refresh asg to apply the lt 
  # aws autoscaling start-instance-refresh --auto-scaling-group-name $myasg
  
  # enable worker ASG metrics
  aws autoscaling enable-metrics-collection --auto-scaling-group-name ${myasg} --granularity "1Minute"
fi

# wait for stack to stabilise
sleep 180



############### Prepare to run the load test ###############
if [ "$type" == "asg" ]; then
  # get lb, asg and policy
  lb_dns=`aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].DNSName' --output text | sed 's/\s\+/\n/g' | grep asg`
  mypolicy_name=`aws autoscaling describe-policies --query "ScalingPolicies[*].PolicyName" --output text | sed 's/\s\+/\n/g' | grep asg`
  policy_json='{ "PredefinedMetricSpecification": { "PredefinedMetricType": "ASGAverageCPUUtilization" }, "TargetValue":'" ${cpu_perc}.0, "'"DisableScaleIn": false}'
  # set max, scale to max
  echo scaling to $max_capacity;
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name ${myasg} --desired-capacity $max_capacity --max-size $max_capacity
  # fix alb healthcheck
  myalb=`aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text`
  aws elb configure-health-check --load-balancer-name ${myalb} --health-check Target=HTTP:$warmup_url,Interval=10,UnhealthyThreshold=6,HealthyThreshold=2,Timeout=5
fi
if [ "$type" == "k8s" ]; then
  # log on to k8s
  aws eks update-kubeconfig --name $cluster_name
  kubectl get svc # quick check
  # get lb
  lb_dns=`kubectl get svc/${app}-svc -o json | jq --raw-output '.status.loadBalancer.ingress[0].hostname'`

  # start k8s metrics collection
  nohup ./k8s-metrics.sh&

  # scale k8s nodes to max
  eksctl scale nodegroup --cluster=$cluster_name --name=standard-workers --nodes=$max_nodes --nodes-max=$max_nodes

  # enable hpa 
  kubectl autoscale deployment ${app}-deployment --cpu-percent=$hpa_perc --min=1 --max=$max_pods
fi

# wait for healthecks
sleep 60

# quick test
curl http://${lb_dns}:${warmup_url}; echo

############### LB warmup run ###############
for((i=$warmup_min_threads;i<=$warmup_max_threads;i+=1));
do
    check_stats $type
    echo [$(date +%FT%T)]${line}[WARMUP RUN c${i}]${line}
    fortio load ${fortio_options} -c $i -t ${warmup_cycle_sec}s -labels "${test}-warmup-${i}" http://${lb_dns}:${warmup_url}
    echo fortio exit code: $?
    check_stats $type
    sleep 60
done

aws elb describe-load-balancers
aws autoscaling describe-auto-scaling-groups
aws ec2 describe-instances  --query 'Reservations[*].Instances[*]' > instance.dump.json # save instance state after warmup, too much to keep in log

############### Performance chunk run ###############
echo [$(date +%FT%T)]${line}[PERFORMANCE CHUNK RUN ${i}]${line}
sleep 60
    for((x=1;x<=5;x+=1));
    do
      check_stats $type
      fortio load -quiet ${fortio_options} -c $warmup_max_threads -t 60s -labels "${test}-performance-chunk-${i}-${x}" http://${lb_dns}:${testing_url}
      echo fortio exit code: $?
    # check_stats $type
    done

############### Performance run ###############
for((i=1;i<=3;i+=1));
do 
    sleep 60
    check_stats $type
    echo [$(date +%FT%T)]${line}[PERFORMANCE RUN ${i}]${line}
    fortio load ${fortio_options} -c $warmup_max_threads -t ${performance_sec}s -labels "${test}-performance-${i}" http://${lb_dns}:${testing_url}
    echo fortio exit code: $?
    check_stats $type
done

echo export t_scaling=$(date +%FT%T) >> metrics_vars.txt

# flush instances to avoid running out of space
if [ "$type" == "asg" ]; then
  echo scaling to 0;
  # 99cpu policy to prevent immideate scaleout on historical data
  aws autoscaling put-scaling-policy --auto-scaling-group-name ${myasg} --policy-name $mypolicy_name --policy-type TargetTrackingScaling --target-tracking-configuration '{ "PredefinedMetricSpecification": { "PredefinedMetricType": "ASGAverageCPUUtilization" }, "TargetValue": 99.0, "DisableScaleIn": false}'
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name ${myasg} --min-size 0 --desired-capacity 0;
  sleep 30
fi

############### Scaling run ###############
for((i=1;i<=3;i+=1));
do
    echo [$(date +%FT%T)]${line}[SCALING RUN $i: INIT]${line}
    if [ "$type" == "asg" ]; then
      # 99cpu policy to prevent immideate scaleout on historical data
      aws autoscaling put-scaling-policy --auto-scaling-group-name ${myasg} --policy-name $mypolicy_name --policy-type TargetTrackingScaling --target-tracking-configuration '{ "PredefinedMetricSpecification": { "PredefinedMetricType": "ASGAverageCPUUtilization" }, "TargetValue": 99.0, "DisableScaleIn": false}'
      # scale to min
      echo scaling to 1;
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name ${myasg} --desired-capacity 1;
      echo [$(date +%FT%T)]${line}[SCALING RUN $i: ENABLE SCALING - SLEEP]${line}
      sleep 160;
      # back to initial policy
      aws autoscaling put-scaling-policy --auto-scaling-group-name ${myasg} --policy-name $mypolicy_name --policy-type TargetTrackingScaling --target-tracking-configuration "${policy_json}"
    fi
    if [ "$type" == "k8s" ]; then
      # delete hpa to prevent immediate scaleout on historical data
      kubectl delete horizontalpodautoscaler.autoscaling/${app}-deployment

      # scale to min
      echo scaling to 1;
      kubectl scale --replicas=1 deployment/${app}-deployment
      eksctl scale nodegroup --cluster=$cluster_name --name=standard-workers --nodes=1
      
      echo [$(date +%FT%T)]${line}[SCALING RUN $i: ENABLE SCALING - SLEEP]${line}
      sleep 160;
      # create the hpa
      kubectl autoscale deployment ${app}-deployment --cpu-percent=$hpa_perc --min=1 --max=$max_pods

    fi

    sleep 20 # let hpa stabilise (collect initial metrics)

    echo [$(date +%FT%T)]${line}[SCALING RUN ${i}: FORTIO]${line}
    for((y=1;y<=$scaling_minutes;y+=1));
    do
      check_stats $type
      echo [$(date +%FT%T)]${line}[SCALING RUN ${i}: CHUNK $y]${line}
      fortio load -quiet ${fortio_options} -c $warmup_max_threads -t 60s -labels "${test}-scaling-${i}-${y}" http://${lb_dns}:${testing_url}
      echo fortio exit code: $?
    done
    check_stats $type
done

# wait for CloudWatch logs to catch up
sleep 240

# save vars for metric query
myalb=`aws elb describe-load-balancers --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text` # repeat here as in the beginning k8s alb isn't yet ready
echo export asg_name=${myasg} >> metrics_vars.txt
echo export lb_name=${myalb} >> metrics_vars.txt
echo export t_end=$(date +%FT%T) >> metrics_vars.txt

echo [$(date +%FT%T)]${line}[GET DATA]${line}
./2.jh-get-data.sh
echo [$(date +%FT%T)]${line}[UPLOAD $(cat 3.upload.noupl.sh | egrep -o '/2022\S+')]${line}
# in case logs grow big, compress them
find . -maxdepth 1 -type f -size +500k -exec zip -m9 backup {} \;
./3.upload.noupl.sh