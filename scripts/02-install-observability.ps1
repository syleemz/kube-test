$ErrorActionPreference = 'Stop'
$infra = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra'

helm repo add grafana https://grafana.github.io/helm-charts | Out-Null
helm repo update grafana | Out-Null

foreach ($ns in 'logging', 'monitoring') {
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
}

# 2026-09 검증 시점 차트 버전 (드리프트 방지용 고정)
helm upgrade --install loki grafana/loki -n logging --version 7.3.0 `
  -f (Join-Path $infra 'loki-values.yaml') --wait --timeout 10m

helm upgrade --install promtail grafana/promtail -n logging --version 6.17.1 `
  -f (Join-Path $infra 'promtail-values.yaml') --wait --timeout 5m

# 대시보드 ConfigMap 을 grafana 설치 전에 생성 (dashboardsConfigMaps 가 참조)
kubectl apply -f (Join-Path $infra 'grafana-dashboard-sample-app.yaml')

helm upgrade --install grafana grafana/grafana -n monitoring --version 10.5.15 `
  -f (Join-Path $infra 'grafana-values.yaml') --wait --timeout 5m

Write-Host ""
kubectl -n logging get pods
kubectl -n monitoring get pods
Write-Host ""
Write-Host "Grafana admin password:"
$b64 = kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
