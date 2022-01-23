# kube-renderer
GitOps is very useful for continous deployment, for continous synchronization from Git to Kubernetes. Most common tool are ArgoCD, Flux, and others.
Common use-case is to prepare changes in deployment as a pull request when ops are able to validate changes before merging and propagating to cluster.

But this may be problematic sometime. When the pull request is about changes in Helm chart o Kustomize like new version of chart, changes in values or something equivalent in the Kustomize world, very small change in Git pull request may cause big changes in final manifests. Yes, the real change is visible in ArgoCD, but it may be too late (because of auto-sync for example).

Because of this some scenarios (especially system-level workload) uses pre-rendering from Helm/Kustomize/... at the level of Git repository and ArgoCD synchonizes final manifests, not Helm charts.

*And this is the job for **kube-renderer**.*
