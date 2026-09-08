$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

Get-Job pf-* -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job

kubectl delete -f (Join-Path $root 'deploy\argocd\application.yaml') --ignore-not-found

helm -n monitoring uninstall grafana
helm -n logging uninstall promtail loki

kubectl delete namespace sample-app logging monitoring argocd --ignore-not-found

docker rmi sample-app:0.1.0 sample-app:0.2.0 2>$null

Write-Host "teardown done"
