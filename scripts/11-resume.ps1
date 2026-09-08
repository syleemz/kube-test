$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $root '.pause-state.json'
$infra = Join-Path $root 'infra'

if (-not (Test-Path $stateFile)) {
  throw "state file not found: $stateFile  (run ./scripts/10-pause.ps1 first)"
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
foreach ($w in $state) {
  $r = if ($w.replicas -ge 1) { $w.replicas } else { 1 }
  kubectl -n $w.ns scale $w.kind $w.name --replicas=$r
}

# restore promtail nodeSelector
kubectl -n logging patch daemonset promtail --type merge --patch-file (Join-Path $infra 'promtail-resume-patch.json')

Remove-Item $stateFile

Write-Host ""
Write-Host "Resumed. Pod status:"
foreach ($ns in 'argocd', 'logging', 'monitoring', 'sample-app') {
  kubectl -n $ns get pods
}
Write-Host ""
Write-Host "Once all Running: ./scripts/05-port-forward.ps1"
