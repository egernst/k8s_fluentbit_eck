todo:
 - [ ] - update Kibana object to set an antiaffinity (lack aarch64 support)
 - [ ] - show example of using fluent-bit annotation to highlight what parser to use.
 
 
# EFK using fluent-bit and the Elastic Operator

ECK provides a higher baseline for security out of the box, which makes most "quick-start" guides for utilizing as
a sink for logging fail. This gist provides details on how to update fluent-bit quick-start guides to work with ECK,
utilizing emptyDir for the ES PVC.

The example below was tested with [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) as well as on a single node baremetal cluster.

## TL; DR: I don't care, let me apply the yaml:

### ECK

```bash
kubectl apply -f https://download.elastic.co/downloads/eck/1.1.2/all-in-one.yaml
kubectl apply -f https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/4c41bb7f519b2f1fbde0a15d79fdcea9c9f59173/monitoring-elastic.yaml
```

Check that Kibana and ElasticSearch are healthy:
```bash
watch -d "kubectl get ElasticSearch,Kibana"
```

Interact with Kibana and Elastic require credentials. The user is elastic, and the password is kept within a secret. This can be obtained as follows:
```bash
PASSWORD=$(kubectl get secret quickstart-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode)
```

Test that ES has the expected base indices:
```bash
kubectl port-forward service/quickstart-es-http 9200 & 
curl -u "elastic:$PASSWORD" -k "https://localhost:9200/_cat/indices?v&pretty"
```

Example output:
```
$ curl -u "elastic:$PASSWORD" -k "https://localhost:9200/_cat/indices?v&pretty"
health status index                    uuid                   pri rep docs.count docs.deleted store.size pri.store.size
green  open   .security-7              uqpSrv44QsKnoHaz25wvRA   1   0         36            0     94.1kb         94.1kb
green  open   .kibana_task_manager_1   8UjmsswKRnOSR2LDmMLOJg   1   0          2            6     51.8kb         51.8kb
green  open   .apm-agent-configuration g_lHlwcaSfaZSwM7tnNWzQ   1   0          0            0       230b           230b
green  open   .kibana_1                etLB5pk1RzWWkxINn8mNYQ   1   0          1            0      5.7kb          5.7kb
```

Kibana should be available to access now through a local web browser

```bash
kubectl port-forward service/quickstart-kb-http 5601 & 
echo $PASSWORD
open https://localhost:5601
```

### Fluent-bit

Setup the service account/CRDs:

Start the daemonset:
```bash
kubectl apply -f https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/e843dc1049adfc71cec49e7ca60ee73385b3b2fb/fluent-bit-role-sa.yaml
kubectl apply -f https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/79ef513c6c8eae656a039fe0ae9a466426e597f1/fluent-bit-configmap.yaml
kubectl apply -f https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/3c112c444bb41ab63fb8815337891baf5cfdc4cd/fluent-bit-ds.yaml
```

Take a look and make sure indices are updated to account for the fluent-bit output (ie, logstash):
```bash
$ curl -u "elastic:$PASSWORD" -k "https://localhost:9200/_cat/indices?v&pretty"
health status index                    uuid                   pri rep docs.count docs.deleted store.size pri.store.size
yellow open   logstash-2020.06.10      81IhKwVVR0KEPyJRABLYZg   1   1       4301            0      1.9mb          1.9mb
green  open   .security-7              uqpSrv44QsKnoHaz25wvRA   1   0         36            0     94.1kb         94.1kb
green  open   .kibana_task_manager_1   8UjmsswKRnOSR2LDmMLOJg   1   0          2            6     51.8kb         51.8kb
green  open   .apm-agent-configuration g_lHlwcaSfaZSwM7tnNWzQ   1   0          0            0       230b           230b
green  open   .kibana_1                etLB5pk1RzWWkxINn8mNYQ   1   0          1            0      5.7kb          5.7kb
```


#  Background 
Describe some of the modifications/challenges I ran into when setting this up.

## ECK Setup:

We start ElasticSearch and Kibana using the ECK operator. This is straightforward, though for ElasticSearch object, we use emptyDir for storage instead of a PVC for ease of setup.

In our case the [resulting manifest](https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/4c41bb7f519b2f1fbde0a15d79fdcea9c9f59173/monitoring-elastic.yaml) for Elasticsearch and Kibana CRDs is standard,
with the following change for Elastic:
```yaml
---
apiVersion: elasticsearch.k8s.elastic.co/v1beta1
kind: Elasticsearch
spec:
  nodeSets:
    podTemplate:
      spec:
        volumes:
        - name: elasticsearch-data
          emptyDir: {}
```          

## Fluentd

It was a challenge to manage using a configmap, but also using environment variable
to share the credential information for connecting to the ES from ECK. If I manually
enter to the configmap this worked fine.  Looking at the fluent-bit documents, it seems
they have better support for managing secrets (ie, their config file can contain variables
which can be pulled from the container's environment). With this, and given the improved efficiency,
let's use fluent-bit instead.

## Fluent-bit

Docs:
[elastic output params](https://docs.fluentbit.io/manual/v/1.0/output/elasticsearch)


The challenge when working with ECK, again, was using TLS and the appropriate credentials. Starting with the
baseline [example of elastic output in k8s](https://docs.fluentbit.io/manual/installation/kubernetes)  configmap from [here](https://raw.githubusercontent.com/fluent/fluent-bit-kubernetes-logging/master/output/elasticsearch/fluent-bit-configmap.yaml), we adjusted the output section to: include user/password, as well as TLS settings:

The [configmap](https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/79ef513c6c8eae656a039fe0ae9a466426e597f1/fluent-bit-configmap.yaml)
changes:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  labels:
    k8s-app: fluent-bit
data:
   output-elasticsearch.conf: |
    [OUTPUT]
        Name            es
        Match           *
        Host            ${FLUENT_ELASTICSEARCH_HOST}
        Port            ${FLUENT_ELASTICSEARCH_PORT}
        HTTP_User       ${FLUENT_ELASTICSEARCH_USER}
        HTTP_Passwd     ${FLUENT_ELASTICSEARCH_PASSWORD}
        Logstash_Format On
        Replace_Dots    On
        Retry_Limit     False
        TLS             On
        TLS.verify      Off
```        

The paser.conf needed to be updated to include the cri parser. CRI adds a timestamp/source information to each log entry. If you use docker parser, the original message will be 'globbed' with these additions. by utilizing the cri parser, the original log will be available in a message field. The parser we use is slightly modified from what is available on fluent-bit respository's parser.conf: we add  `Decode_Field json message` . This was done in order to be able to parse logrus / json strucuted output automatically. Perhaps there's a way that we could chain parsers? In the meantime, the resulting addition:
```
    [PARSER]
        Name        cri
        Format      regex
        Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z
        Decode_Field json message
```        

The [INPUT] stage of the configmap needed to be updated to leverage this cri parser, modifiying Parser from docker to cri.
       
The [daemonset](https://gist.githubusercontent.com/egernst/d8f20021db724ba831a2552ba02027fe/raw/3c112c444bb41ab63fb8815337891baf5cfdc4cd/fluent-bit-ds.yaml) is based off of the example above, with the following additions for container variables:      
        
```yaml
apiVersion: apps/v1
kind: DaemonSet
spec:
  template:
    spec:
      containers:
        env:
        - name: FLUENT_ELASTICSEARCH_HOST
          value: "quickstart-es-http"
        - name: FLUENT_ELASTICSEARCH_PORT
          value: "9200"
        - name: FLUENT_ELASTICSEARCH_USER
          value: "elastic"
        - name: FLUENT_ELASTICSEARCH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: quickstart-es-elastic-user
              key: elastic
```
