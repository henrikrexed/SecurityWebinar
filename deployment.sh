#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
### type: defines which solution would be deployed in the cluster ( falco, tetragon or kubearmor)
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
if ! command -v oc >/dev/null 2>&1; then
    echo "Please install oc before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
          DTOPERATORTOKEN="$2"
         shift 2
          ;;
       --dtingesttoken)
          DTTOKEN="$2"
         shift 2
          ;;
       --dturl)
          DTURL="$2"
         shift 2
          ;;
       --clustername)
         CLUSTERNAME="$2"
         shift 2
         ;;

  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
 if [ -z "$CLUSTERNAME" ]; then
   echo "Error: clustername not set!"
   exit 1
 fi
 if [ -z "$DTURL" ]; then
   echo "Error: Dt url not set!"
   exit 1
 fi

 if [ -z "$DTTOKEN" ]; then
   echo "Error: Data ingest api-token not set!"
   exit 1
 fi

 if [ -z "$DTOPERATORTOKEN" ]; then
   echo "Error: DT operator token not set!"
   exit 1
 fi
### installing the opentelemetry operator

echo "installing the opentelemetry operator from operator hub"
oc apply -f - << EOF
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  labels:
    kubernetes.io/metadata.name: openshift-opentelemetry-operator
    openshift.io/cluster-monitoring: "true"
  name: openshift-opentelemetry-operator
EOF

oc apply -f - << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-opentelemetry-operator
  namespace: openshift-opentelemetry-operator
spec:
  upgradeStrategy: Default
EOF

oc apply -f - << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-opentelemetry-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc get csv -n openshift-opentelemetry-operator


#### Deploy the Dynatrace Operator

sed -i "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml



#Deploy collector
echo "installing the opentelemetry collectors "
oc project default
oc create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=clustername="$CLUSTERNAME"  --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN" -n default
oc label namespace  default oneagent=false
kubectl apply -f opentelemetry/rbac.yaml
oc apply -f opentelemetry/scc.yaml
oc adm policy add-scc-to-user collector  otelcontribcol -n default
oc apply -f opentelemetry/openTelemetry-manifest_ds.yaml -n default
oc apply -f opentelemetry/openTelemetry-manifest_statefulset.yaml -n default

#deploy dyntrace operator
echo "installing Dynatrace operator"
oc new-project dynatrace
oc project dynatrace
helm install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
    --set "csidriver.enabled=false" \
   --create-namespace \
   --namespace dynatrace \
   --atomic
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"

oc apply -f dynatrace/dynakube.yaml -n dynatrace
echo "installing otel-demo"
oc new-project otel-demo
oc project otel-demo
oc create sa opentelemetry-demo
oc adm policy add-scc-to-user anyuid -z opentelemetry-demo -n otel-demo
oc label namespace  otel-demo oneagent=false
kubectl apply -f opentelemetry/deploy_1_11.yaml -n otel-demo

echo "installing Goat-app"
oc new-project goat-app
oc project goat-app
oc label namespace  goat-app oneagent=false
oc create sa internal-kubectl -n goat-app
oc adm policy add-scc-to-user anyuid -z internal-kubectl -n goat-app

kubectl apply -f k8sGoat/unsafejob.yaml -n goat-app

echo "installing unguard"
oc new-project unguard
oc project unguard
oc label namespace  unguard oneagent=true
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install unguard-mariadb bitnami/mariadb  --version 11.5.7 --set primary.persistence.enabled=false --wait --namespace unguard  --set global.compatibility.openshift.adaptSecurityContext=force
oc adm policy add-scc-to-user anyuid -z unguard-mariadb -n unguard
helm uninstall unguard-mariadb
helm install unguard-mariadb bitnami/mariadb  --version 11.5.7 --set primary.persistence.enabled=false --wait --namespace unguard  --set global.compatibility.openshift.adaptSecurityContext=force
helm install unguard  oci://ghcr.io/dynatrace-oss/unguard/chart/unguard --set maliciousLoadGenerat.enabled=true --wait --namespace unguard
oc create sa unguard-user -n unguard
oc adm policy add-scc-to-user  privileged  unguard-user -n unguard
kubectl apply -f unguard/payment-service.yaml -n unguard
kubectl apply -f unguard/profile-service.yaml -n unguard





