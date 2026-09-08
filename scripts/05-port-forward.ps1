$ErrorActionPreference = 'Stop'

# 백그라운드 job 으로 3개 서비스 포트포워딩. 셸을 닫으면 job 도 종료됨.
$forwards = @(
  @{ name = 'grafana'; ns = 'monitoring'; svc = 'svc/grafana';      local = 3000; remote = 80 },
  @{ name = 'app';     ns = 'sample-app'; svc = 'svc/sample-app';    local = 8080; remote = 80 },
  @{ name = 'argocd';  ns = 'argocd';     svc = 'svc/argocd-server'; local = 8081; remote = 443 }
)

Get-Job pf-* -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job

foreach ($f in $forwards) {
  Start-Job -Name "pf-$($f.name)" -ScriptBlock {
    param($ns, $svc, $l, $r)
    kubectl -n $ns port-forward $svc "${l}:${r}"
  } -ArgumentList $f.ns, $f.svc, $f.local, $f.remote | Out-Null
}

Start-Sleep -Seconds 2
Get-Job pf-*

Write-Host ""
Write-Host "Grafana  http://localhost:3000    (admin / admin)"
Write-Host "App      http://localhost:8080/health"
Write-Host "ArgoCD   https://localhost:8081"
Write-Host ""
Write-Host "중지:  Get-Job pf-* | Stop-Job; Get-Job pf-* | Remove-Job"
