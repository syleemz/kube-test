$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $root '.pause-state.json'
$infra = Join-Path $root 'infra'

$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }

if ($state) {
  foreach ($w in $state) {
    $r = if ($w.replicas -ge 1) { $w.replicas } else { 1 }
    kubectl -n $w.ns scale $w.kind $w.name --replicas=$r
  }

  # restore promtail nodeSelector
  kubectl -n logging patch daemonset promtail --type merge --patch-file (Join-Path $infra 'promtail-resume-patch.json')

  Remove-Item $stateFile

  Write-Host ""
  Write-Host "Waiting for workloads to become ready..."
  foreach ($w in $state) {
    kubectl -n $w.ns rollout status $w.kind $w.name --timeout=120s
  }
  kubectl -n logging rollout status daemonset promtail --timeout=120s
}
else {
  Write-Host "No pause state ($stateFile) - assuming stack is already running."
  Write-Host "Restarting port-forwards only."
}

# start (or restart) port-forwards in this session
$pf = Join-Path $PSScriptRoot '05-port-forward.ps1'
if (Test-Path $pf) {
  Write-Host ""
  Write-Host "Starting port-forwards..."
  & $pf
}
else {
  Write-Host ""
  Write-Host "Done. Start port-forwards with: ./scripts/05-port-forward.ps1"
}
