#!/bin/bash
set -x

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl apply -f cluster-autoscaler-autodiscover.yaml

kubectl apply -f taro.yaml
kubectl apply -f nginx.yaml

kubectl autoscale deployment taro-deployment --cpu-percent=50 --min=1 --max=10
kubectl autoscale deployment nginx-deployment --cpu-percent=50 --min=1 --max=10

kubectl get pods --all-namespaces
kubectl get deployments
kubectl get svc