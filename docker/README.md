# Lab: configuration, state, and load — Docker

For laptops running **Docker Desktop**. On Podman, use `../podman` instead.

Three labs, roughly 20 minutes each, one per act. If something doesn't behave the way
it says, that's worth shouting about.

Before each command, have a guess at what will happen. That's the point of it. A wrong
guess teaches us more than a command that just quietly works.

---

## Lab 0 — Get a cluster (5 min, do it during the intro)

```bash
cd docker
k3d cluster create --config k3d-config.yaml
kubectl config use-context k3d-exchange
kubectl get nodes
```

Three nodes. k3s already includes **Traefik**, so Ingress works, and **metrics-server**,
so autoscaling works. Nothing else to install.

Build the app and hand it to the cluster:

```bash
docker build -t exchange-gateway:v1 ./app
k3d image import exchange-gateway:v1 -c exchange
```

Use the same name in both commands and in the manifests. Kubernetes reads
`exchange-gateway:v1` as `docker.io/library/exchange-gateway:v1`, which is exactly the name
Docker gives the image, so the imported copy is found and nothing is pulled.

Validate the manifests before applying anything, the habit from our last course:

```bash
kubeconform -strict -ignore-missing-schemas act1-config/*.yaml
```

> **On `kind` instead of `k3d`?** Use `kind-config.yaml`, then run
> `bash scripts/setup-kind-extras.sh` to install the ingress controller and
> metrics-server that k3s hands us for free. Load the image with
> `kind load docker-image exchange-gateway:v1 --name exchange`.
> Everything after this point is identical.

---

## Lab 1 — Configure it from outside (20 min)

### 1a. The config the image should not contain

```bash
kubectl apply -f act1-config/configmap.yaml
```

Open `act1-config/deployment.yaml` and find the **two different routes** the same
ConfigMap takes into the container: `envFrom` for environment variables, and a
`volumeMounts` entry for files under `/etc/gateway`.

### 1b. A secret, created properly

Never write a real secret into a manifest we commit. Create it from the command line instead:

```bash
kubectl create secret generic market-data-feed \
  --from-literal=API_KEY='super-secret-key-1234'
```

### 1c. Bring it up, with a front door

```bash
kubectl apply -f act1-config/
kubectl rollout status deployment/gateway
```

Open **http://localhost:8088**

We're reaching a `ClusterIP` Service through an Ingress. The Service itself isn't exposed
at all. Notice the two tick-size panels: both read `0.01`, one from an environment
variable and one from a mounted file.

### 1d. The question that catches everyone

```bash
kubectl patch configmap gateway-config --type=merge -p '{"data":{"TICK_SIZE":"0.05"}}'
```

**Guess first:** which of the two panels changes, and how long does it take?

Now wait, and keep an eye on the page. **This takes about a minute.** Go and read
`act1-config/deployment.yaml` while it happens; nothing is broken.

Measured on a laptop: the **mounted file changed after 64 seconds**. The **environment
variable never changed at all**, because it was read once when the process started and
frozen there. The page flags it when the two disagree.

Make them agree again:

```bash
kubectl rollout restart deployment/gateway
```

> This is why "I updated the ConfigMap and nothing happened" is one of the most common
> Kubernetes questions there is. Changing config usually means restarting pods, and
> `rollout restart` does that without dropping traffic.

### 1e. base64 is not encryption

```bash
kubectl get secret market-data-feed -o jsonpath='{.data.API_KEY}' | base64 -d
```

There it is, in plaintext, in one line. The page only ever shows it masked, but the
cluster will hand the whole thing to anyone who can read secrets in this namespace.

**Checkpoint:** we changed the tick size without rebuilding the image, and we can explain
why the first attempt looked like it did nothing.

**Stuck?** Every manifest in `act1-config/` is already complete, so apply the whole
directory and read them afterwards. `solutions/gateway-final.yaml` is the end-state
Deployment if we need to jump ahead.

---

## Lab 2 — Give it a memory (20 min)

### 2a. Storage that does not survive

```bash
kubectl apply -f act2-state/deployment-emptydir.yaml
kubectl rollout status deployment/engine
```

Record three orders, and check the count:

```bash
POD=$(kubectl get pod -l app=engine -o jsonpath='{.items[0].metadata.name}')
for i in 1 2 3; do kubectl exec $POD -- wget -qO- --post-data='' http://localhost:3000/api/order; done
kubectl exec $POD -- wget -qO- http://localhost:3000/api/state | grep -o '"orders":[0-9]*'
```

That last line only *reads* the count, and should print `"orders":3`. Don't re-run the
loop to check; every run of it places three more orders.

Now delete the pod and wait for its replacement:

```bash
kubectl delete pod $POD
kubectl rollout status deployment/engine
```

`$POD` still holds the old pod's name, which no longer exists. Look the new one up, then
check its count:

```bash
POD=$(kubectl get pod -l app=engine -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- wget -qO- http://localhost:3000/api/state | grep -o '"orders":[0-9]*'
```

**`"orders":0`.** `emptyDir` survives a *container* restart, not a *pod* replacement.

> **Prefer the UI?** `localhost:8088` still shows the `gateway` pods from Lab 1; nothing
> routes to `engine`. Forward a port straight to it, in a second terminal:
> `kubectl port-forward deployment/engine 8090:3000`, then open `localhost:8090`. The
> **Persisted state** card shows the count, and **place an order** adds one. A
> port-forward is tied to one pod, so it stops when that pod is deleted; start it again
> once the replacement is ready.

### 2b. Identity that survives

```bash
kubectl delete -f act2-state/deployment-emptydir.yaml
kubectl apply -f act2-state/statefulset.yaml
kubectl rollout status statefulset/engine
kubectl get pods -l app=engine
kubectl get pvc
```

Three pods (`engine-0`, `engine-1`, `engine-2`) and three claims, one each:
`data-engine-0`, `data-engine-1`, `data-engine-2`. Nobody wrote those claims. The
`volumeClaimTemplates` block created one per pod.

Write to exactly one of them:

```bash
for i in 1 2 3 4 5; do kubectl exec engine-1 -- wget -qO- --post-data='' http://localhost:3000/api/order; done
```

Check all three:

```bash
for p in engine-0 engine-1 engine-2; do printf '%s  ' $p; kubectl exec $p -- wget -qO- http://localhost:3000/api/state | grep -o '"orders":[0-9]*'; done
```

Only `engine-1` has five orders, because each pod owns its own storage.

**Now the moment:**

```bash
kubectl delete pod engine-1
kubectl wait --for=condition=Ready pod/engine-1
kubectl exec engine-1 -- wget -qO- http://localhost:3000/api/state | grep -o '"orders":[0-9]*'
```

**The same name came back, with the same five orders.** A Deployment couldn't have done
that. It would have given us a new random name attached to nothing.

### 2c. Order, and what is deliberately kept

```bash
kubectl get pods -l app=engine -w      # leave this running
kubectl scale statefulset/engine --replicas=1
```

They stop in **reverse order**: `engine-2` first, then `engine-1`. Ctrl-C when done.

```bash
kubectl get pvc
```

All three claims are still there. Kubernetes won't throw our data away to satisfy a
replica count. Scale back to 3 and the old data comes back with the pods.

**Checkpoint:** we deleted a stateful pod and it came back with the same name and the
same data, and we can say why a Deployment couldn't have done that.

---

## Lab 3 — Under load (22 min)

```bash
kubectl delete -f act2-state/statefulset.yaml
kubectl apply -f act3-load/deployment-tight-memory.yaml
```

### 3a. Memory kills loudly

The limit is `128Mi`. On the page, press **hold +32 MB** repeatedly.

**Guess first:** what happens on the fourth press?

Measured: 32 MB, 64 MB, 96 MB, then the page stops answering for a moment and comes back
with the counter at zero.

```bash
kubectl get pods -l app=gateway
kubectl get pod -l app=gateway -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'
```

`RESTARTS` is 1 and the reason is **OOMKilled**. Loud, obvious, written down for us.

### 3b. Autoscaling

```bash
kubectl top pods -l app=gateway      # metrics must work before the HPA can
kubectl apply -f act3-load/hpa.yaml
kubectl get hpa gateway -w
```

Generate load — press **burn cpu · 5s** on the page a few times, or from a few terminals:

```bash
while true; do curl -s "localhost:8088/api/burn?ms=400" > /dev/null; done
```

Measured: **2 → 6 → 10 replicas**. Read the reason yourself:

```bash
kubectl describe hpa gateway | tail -6
```

> `cpu resource utilization (percentage of request) above target`
>
> **Percentage of request.** Delete the `requests.cpu` line from the Deployment and the
> HPA has no denominator. It reports `<unknown>` and never scales. Worth trying.

Stop the load and watch it scale back down — slowly, on purpose.

### 3c. Shipping while people are using it

```bash
kubectl delete hpa gateway
kubectl scale deployment/gateway --replicas=4
kubectl patch deployment gateway --patch-file act3-load/rollout-strategy.yaml
```

That patch sets `maxSurge: 1, maxUnavailable: 0`, so we never drop below four pods serving.

Build and import version 2 first, so the rollout can start the moment you want it:

```bash
docker build -t exchange-gateway:v2 ./app
k3d image import exchange-gateway:v2 -c exchange
```

In one terminal, start counting. This sends 1,200 requests, takes about a minute and a
half, then prints how many came back with each status code. **Let it finish**: stopping it
with Ctrl-C also stops it from printing anything.

```bash
for i in $(seq 1 1200); do curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 localhost:8088/api/state; sleep 0.05; done | sort | uniq -c
```

Within ten seconds, in a second terminal, ship the new version:

```bash
kubectl set image deployment/gateway gateway=exchange-gateway:v2
kubectl rollout status deployment/gateway
```

When the counter finishes, every code other than `200` is a failed request: `000` means
the connection failed, and `502` means the ingress had no pod to send it to.
**Measured on k3d: 4 failed out of 1,200, in each of two runs.** Not zero, and that's
the interesting part.

`maxUnavailable: 0` protects our *capacity*. It doesn't protect requests already in flight
to a pod that's going away. The pod is taken out of the Service endpoints and sent
`SIGTERM` at the same moment, and that removal takes a little while to reach every proxy.

```bash
kubectl patch deployment gateway --patch-file act3-load/graceful-patch.yaml
kubectl rollout status deployment/gateway
```

That adds a five-second `preStop` sleep, which holds the container open while the endpoint
removal spreads. Now count again: start the counter, and within ten seconds roll back to v1.

```bash
kubectl set image deployment/gateway gateway=exchange-gateway:v1
kubectl rollout status deployment/gateway
```

Use `set image` rather than `kubectl rollout undo` here. The previous revision is v2
*without* the `preStop` hook, so undo would take away the thing we're testing.

**Measured on k3d: 2 failed out of 1,200, then 0 in a second run.** Better, but not
reliably zero.

> "Zero downtime" isn't one setting. It's capacity (`maxUnavailable`), plus readiness
> gating, plus graceful shutdown, plus `preStop`, plus clients that retry. Each layer
> removes some of the failures. Anyone who says one YAML field buys zero downtime
> hasn't measured it.

**Checkpoint:** we shipped a new version to a live service, we can say how many requests
failed, and we can name two separate things that brought that number down.

---

## When we are finished

```bash
bash scripts/reset.sh
```

Deletes the `exchange` cluster and the images. Touches nothing else on the machine.

---

## Troubleshooting

**`couldn't get resource list for metrics.k8s.io/v1beta1: the server is currently unable to handle the request`.**
Harmless, and normal for the first minute after creating the cluster. `kubectl` (and
`oc`) look up every API the cluster offers before running a command, and metrics-server
takes 40–60 seconds to start. The command itself still runs. Once
`kubectl top nodes` shows numbers, the warnings stop.

**`localhost:8088` doesn't answer.** Something else may own the port. Check with
`lsof -i :8088`, then change the left-hand number in `k3d-config.yaml` and recreate the
cluster.

**`ImagePullBackOff`.** Check the import and the manifest use the same image name. Otherwise
we skipped `k3d image import`, or we're pointed at the wrong cluster. Check with `kubectl config current-context`; it should say `k3d-exchange`.

**Some pods hit `ImagePullBackOff` later, even though the image was imported.** Usually
only pods on one node. Once the disk is 85% full, Kubernetes deletes images that no pod
on that node is using, and our image is imported rather than pulled, so it can't come
back on its own. Clusters made from this folder's `k3d-config.yaml` only do that above
95%. For an older cluster, or a disk above 95%, import the image again and check free
space:

```bash
k3d image import exchange-gateway:v1 -c exchange
docker system df
```

**The HPA shows `<unknown>`.** metrics-server isn't ready yet (give it a minute), or the
Deployment has no `requests.cpu`.

**The mounted file won't update.** Give it a full minute. If it still hasn't moved, check
we mounted the whole ConfigMap and didn't use `subPath`, which never updates.

**Pods stuck `Pending`.** Usually a PVC that can't bind, or a node without room. Run
`kubectl describe pod <name>` and read the events at the bottom.
