## k8s-become-pod

Develop k8s apps in your local environment, with full connectivity to and from remote k8s resources.

It's like stuffing your laptop inside a k8s pod.

#### Setup

1. Install and configure `kubectl` locally, so that remote commands can be run from your local environment.<br/>
1. Install [sshuttle](https://github.com/sshuttle/sshuttle) and `socat`<br/>
   `brew install sshuttle socat` (OSX)<br/>
   or<br/>
   `apt-get install sshuttle socat` (debian linux)
1. Run `./connect.sh` on your laptop.<br/>
   (You should now be able to connect to k8s resources by IP & by DNS name.)
1. Run `./redirect.sh [--namespace=<namespace>] <service ...>`<br/>
   (Any program that connects to the specified service(s) should now be redirected to your machine.)

That's it!

#### Teardown

1. Run `./redirect.sh --revert [--namespace=<namespace>] <service ...>`<br/>
   or<br/>
   `./redirect.sh --revert-all`.
1. `Ctrl-C` the `./connect.sh` process.


#### Current Gotcha's

* Only fully-qualified k8s DNS names will be resolved by the k8s DNS service (must end in `*.cluster.local`).
* Only TCP traffic is supported.
* `./connect.sh` must be running (and remain running) in order for `./redirect.sh` to function.

#### How it works

Proxy pods are deployed into the k8s environment (on-demand, typically one per namespace).

**Outgoing TCP traffic:**<br/>
In the local environment, any traffic that has a destination in the k8s subnet range, is sent to the proxy pod by [sshuttle](https://github.com/sshuttle/sshuttle).

**Outgoing DNS traffic:**<br/>
Any DNS requests with an address ending in `*.cluster.local` is sent to the proxy pod, and then is forwarded from there on to the k8s DNS service.

**Incoming TCP traffic:**<br/>
A service's traffic is redirected to the proxy pod by; the pod then forwards it to the local environment using ssh port forwarding.
