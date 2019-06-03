## k8s-become-pod

Develop k8s apps in your local environment, with full connectivity to and from remote k8s resources.

It's like stuffing your laptop inside a k8s pod.

#### Cluster setup

1. Change tags in `become-proxy.yml` so that the deployed container will receive traffic for the pod you would like to develop.
2. Delete existing instances of this pod.
3. Deploy `become-proxy.yml`

or, alternatively (if the pod requires a bunch of custom config, or contains multiple containers)

1. Drop-in-replace a container image with `khagerma/become-proxy`
2. Add a tag to the pod, so that `become-proxy-service.yml` can direct connections to the pod.<br/>
   Default is `proxy: unique-tag`.
3. Redeploy affected pods.
4. Deploy `become-proxy-service.yml`

Traffic should now be directed to the proxy container instead of the deployment container.

#### Local setup

1. Install `sshuttle` and `socat`<br/>
   `brew install sshuttle socat` (OSX)<br/>
   or<br/>
   `apt-get install sshuttle socat` (debian linux)
2. Run `./connect.sh <any-node-ip>[:<port>] <ports...>`<br/>
   where <ports...> is a list of ports that should proxy incoming traffic.<br/>
   
That's it!

Programs running in the cluster should now be able to connect to local servers, and
local programs should be able to access cluster resources.

#### Current Gotcha's

* Only fully-qualified DNS requests will resolve into k8s (must end in `*.cluster.local`).
* Only TCP traffic is supported.
* The local machine should only be connected to one proxy pod at any given time.
* Cannot determine the k8s subnet size. `/16` is assumed.

#### How it works

Incoming TCP traffic is forwarded using ssh port forwarding.

Outgoing TCP traffic (destined for the k8s subnet) is proxied into the pod by sshuttle, 
allowing the local machine to reach k8s resources.

DNS traffic is split, all lookups with addresses ending in `*.cluster.local` are sent to the server.
