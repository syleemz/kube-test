$ErrorActionPreference = 'Stop'

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: ApplicationSet CRD 가 커서 client-side apply 는 annotation 크기 제한에 걸림
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
$pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

Write-Host ""
Write-Host "ArgoCD  admin / $pw"
Write-Host "port-forward:  kubectl -n argocd port-forward svc/argocd-server 8081:443   -> https://localhost:8081"
Write-Host ""
Write-Host "다음: deploy/argocd/application.yaml 의 repoURL 을 본인 GitHub 레포로 바꾼 뒤"
Write-Host "      kubectl apply -f deploy/argocd/application.yaml"
