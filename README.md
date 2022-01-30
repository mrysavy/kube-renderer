# kube-renderer
GitOps is very useful for continous deployment, for continous synchronization from Git to Kubernetes. Most common tool are ArgoCD, Flux, and others.
Common use-case is to prepare changes in deployment as a pull request when ops are able to validate changes before merging and propagating to cluster.

But this may be problematic sometime. When the pull request is about changes in Helm chart o Kustomize like new version of chart, changes in values or something equivalent in the Kustomize world, very small change in Git pull request may cause big changes in final manifests. Yes, the real change is visible in ArgoCD, but it may be too late (because of auto-sync for example).

Because of this some scenarios (especially system-level workload) uses pre-rendering from Helm/Kustomize/... at the level of Git repository and ArgoCD synchonizes final manifests, not Helm charts.

*And this is the job for **kube-renderer**.*

## background
**kube-renderer** is based on the following amazing tools (an alphabetical order):

* [bash](https://www.gnu.org/software/bash/) - yes, this is written in `bash`
* [bats](https://github.com/bats-core/bats-core) - every tool needs some tests
* [helm](https://helm.sh/) v3 - `helm` is the a hearth of helmfile and kube-renderer as well
* [helmfile](https://github.com/roboll/helmfile) - kube-renderer is based on multi-functional tool `helmfile` and process its input and output
* [kustomize](https://kustomize.io/) - `kustomize` is not only used by helmfile, but also is used as an alternative unique filename generator
* [yq](https://mikefarah.gitbook.io/yq/) v4 - `yq` is a multipurpose tool used for yaml files manipulation and as a customizable unique filename generator
* [gomplate](https://gomplate.ca/) - `gomplate` is a go-templates engine used for pre-rendering any files, but mainly used when helmfile doesn't support templating

Many thanks to authors of these tools.
