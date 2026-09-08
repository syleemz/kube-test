$ErrorActionPreference = 'Stop'
$stateFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.pause-state.json'

if (-not (Test-Path $stateFile)) {
  throw "state 파일이 없습니다: $stateFile  (먼저 ./scripts/10-pause.ps1 실행)"
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
foreach ($w in $state) {
  $r = if ($w.replicas -ge 1) { $w.replicas } else { 1 }
  kubectl -n $w.ns scale $w.kind $w.name --replicas=$r
}

# promtail nodeSelector 원복
kubectl -n logging patch daemonset promtail --type merge `
  -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'

Remove-Item $stateFile

Write-Host ""
Write-Host "resume 완료. 파드 상태:"
foreach ($ns in 'argocd', 'logging', 'monitoring', 'sample-app') {
  kubectl -n $ns get pods
}
Write-Host ""
Write-Host "모두 Running 되면: ./scripts/05-port-forward.ps1"
