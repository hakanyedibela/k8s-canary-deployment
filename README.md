# Canary Deployment in Kubernetes 

This is a simple explaination of how to drive a canary deployment under K8S. 

## Steps to create a simple canary deployment

### 1. Craate canary namespace

```Shell
kubectl create ns canary
```

### 2. Create canary-deploy yaml

```Shell
kubectl apply -f canary-deploy.yaml
```

### 3. Expose canary-deploy deployment

```Shell
kubectl expose deploy canary-deploy -n canary --port=18080 --name=canary-svc --selector=type=canary
```

Check the service and endpoints for the deployment if everything is running like expected.

```Shell
kubeclt get svc -n canary; kubectl get ep -n canary
```
OR
```Shell
kubectl describe canary-svc -n canary
```

Export the Cluster-IP into a IP variable.


Optional: Test the deployment service with a temp busybox pod

```Shell
kubectl tmp --image=busybox -n canary -it --rm --restart=Never -- /bin/sh -c 'wget -O- $IP:18080/developer'
```

### 4. Create the new canary deployment
```Shell
kubectl apply -f canary-deploy-new.yaml
```

Check the service of the canary-svc again. There have to be appear one more endpoint for the new canary deployment.

### 5. Test the canary deployment
This is simple test with a busybox container. Sending every 3 seconds the wget command to the service endpoint, should show different outputs.

```Shell
kubectl tmp --image=busybox -n canary -it --rm --restart=Never -- /bin/sh -c 'while true; do sleep 3; wget -O- $IP:18080/developer; done'
```

