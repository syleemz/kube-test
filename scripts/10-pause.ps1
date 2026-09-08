$ErrorActionPreference = 'Stop'
$stateFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.pause-state.json'
# argocd 를 먼저 내려야 self-heal 이 다른 워크로드를 되살리지 않음
$namespaces = 'argocd', 'logging', 'monitoring', 'sample-app'

# 현재 replica 수를 저장 (이미 pause 중이면 기존 파일 유지)
if (Test-Path $stateFile) {
  Write-Host "이미 pause 상태입니다 ($stateFile). 재적용만 수행."
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
  Write-Host "저장: $($state.Count) 개 워크로드 -> $stateFile"
}

# 1) ArgoCD application-controller 먼저 정지 (self-heal 차단)
$ctrl = $state | Where-Object { $_.name -eq 'argocd-application-controller' }
if ($ctrl) {
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
  kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=60s 2>$null
}

# 2) 나머지 전부 0
foreach ($w in $state) {
  kubectl -n $w.ns scale $w.kind $w.name --replicas=0
}

# 3) promtail(DaemonSet)은 매칭 안 되는 nodeSelector 로 파드 제거
kubectl -n logging patch daemonset promtail --type merge `
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kube-test/paused":"true"}}}}}'

Write-Host ""
Write-Host "pause 완료. 재개: ./scripts/11-resume.ps1"
