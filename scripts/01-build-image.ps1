param([string]$Tag = '0.1.0')
$ErrorActionPreference = 'Stop'

# Rancher Desktop runtime is cri-dockerd, so `docker build` alone makes the image visible to k3s.
$root = Split-Path -Parent $PSScriptRoot
docker build -t "sample-app:$Tag" (Join-Path $root 'app')

Write-Host ""
Write-Host "Built sample-app:$Tag  (k3s uses the local image via imagePullPolicy: IfNotPresent)"
docker images sample-app
