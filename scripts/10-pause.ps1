$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $root '.pause-state.json'
$infra = Join-Path $root 'infra'
# argocd first so its self-heal does not revive the other workloads
$namespaces = 'argocd', 'logging', 'monitoring', 'sample-app'

# save current replica counts (keep existing file if already paused)
if (Test-Path $stateFile) {
  Write-Host "Already paused ($stateFile). Re-applying scale-down only."
  $state = Get-Content $stateFile -Raw | ConvertFrom-Json
}
else {
  $state = @()
  foreach ($ns in $namespaces) {
    $items = (kubectl -n $ns get deployment,statefulset -o json | ConvertFrom-Json).items
    foreach ($it in $items) {
      $state += [pscustomobject]@{
        ns       = $ns
        kind     = $it.kind.ToLower()
        name     = $it.metadata.name
        replicas = [int]$it.spec.replicas
      }
    }
  }
  $state | ConvertTo-Json | Set-Content $stateFile
  Write-Host "Saved $($state.Count) workloads -> $stateFile"
}

# 1) stop argocd application-controller first (blocks self-heal)
if ($state | Where-Object { $_.name -eq 'argocd-application-controller' }) {
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
  kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=60s 2>$null
}

# 2) scale everything to 0
foreach ($w in $state) {
  kubectl -n $w.ns scale $w.kind $w.name --replicas=0
}

# 3) promtail is a DaemonSet: park it with a non-matching nodeSelector
kubectl -n logging patch daemonset promtail --type merge --patch-file (Join-Path $infra 'promtail-pause-patch.json')

Write-Host ""
Write-Host "Paused. Resume with: ./scripts/11-resume.ps1"
