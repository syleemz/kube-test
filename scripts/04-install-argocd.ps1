$ErrorActionPreference = 'Stop'

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the ApplicationSet CRD is too large for client-side apply's annotation size limit
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
$pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

Write-Host ""
Write-Host "ArgoCD  admin / $pw"
Write-Host "port-forward:  kubectl -n argocd port-forward svc/argocd-server 8081:443   -> https://localhost:8081"
Write-Host ""
Write-Host "Next: set repoURL in deploy/argocd/application.yaml to your GitHub repo, then"
Write-Host "      kubectl apply -f deploy/argocd/application.yaml"
