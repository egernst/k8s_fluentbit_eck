#!/bin/bash

kind delete cluster
kind create cluster --config=./config.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/1.1.2/all-in-one.yaml
kubectl apply -f monitoring-elastic.yaml

while [[ $(kubectl get kibana -o=jsonpath='{.items[0].status.health}') != "green" ]]; do echo "waiting for kibana" && sleep 5; done

kubectl apply -f fluent-bit-role-sa.yaml
kubectl apply -f fluent-bit-configmap.yaml
kubectl apply -f fluent-bit-ds.yaml

expected=$(kubectl get ds fluent-bit -o json | jq '.status.desiredNumberScheduled')
while [[ $(kubectl get ds fluent-bit -o=jsonpath="{.status.numberReady}") != "$expected" ]]; do echo "waiting for ds" && sleep 5; done

kubectl create ns jobs
kubectl apply -n jobs -f job.yaml

