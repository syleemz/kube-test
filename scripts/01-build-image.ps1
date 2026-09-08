param([string]$Tag = '0.1.0')
$ErrorActionPreference = 'Stop'

# Rancher Desktop: 컨테이너 런타임이 cri-dockerd 이므로 docker build 만으로 k3s 가 이미지를 인식.
$root = Split-Path -Parent $PSScriptRoot
docker build -t "sample-app:$Tag" (Join-Path $root 'app')

Write-Host ""
Write-Host "Built sample-app:$Tag  (imagePullPolicy: IfNotPresent 로 k3s 가 로컬 이미지 사용)"
docker images sample-app
