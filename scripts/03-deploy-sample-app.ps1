$ErrorActionPreference = 'Stop'
$deploy = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy\sample-app'

kubectl create namespace sample-app --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k $deploy
kubectl -n sample-app rollout status deploy/sample-app --timeout=120s

Write-Host ""
kubectl -n sample-app get pods -o wide
