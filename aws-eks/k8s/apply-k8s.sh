#!/bin/bash
kubectl apply -f nginx-svc.yaml
sleep 2s
kubectl apply -f nginx-deployment.yaml

kubectl get deployments
kubectl get svc
