[CmdletBinding()]
param(
    [string]$FrontendRepository = 'git@github.com:ctava-msft/clinical-unit-frontend.git',
    [string]$BackendRepository = 'git@github.com:ctava-msft/clinical-unit-backend.git',
    [string]$SourceRef = 'main',

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9.-]+$')]
    [string]$RegistryLoginServer,

    [ValidatePattern('^[a-zA-Z0-9_.-]+$')]
    [string]$ImageTag = (Get-Date -Format 'yyyyMMddHHmmss'),

    [ValidateSet('linux/amd64', 'linux/arm64')]
    [string]$ContainerPlatform = 'linux/amd64',

    [ValidatePattern('^https://')]
    [string]$NpmRegistry = 'https://registry.npmjs.org/',

    [ValidatePattern('^https://')]
    [string]$PythonPackageIndex = 'https://pypi.org/simple/',

    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "clinical-unit-build-$([guid]::NewGuid().ToString('N'))"
$frontendSource = Join-Path $temporaryRoot 'frontend'
$backendSource = Join-Path $temporaryRoot 'backend'

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Get-Repository {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Destination
    )

    Invoke-ExternalCommand -Command git -Arguments @('clone', '--filter=blob:none', '--no-checkout', $Repository, $Destination)
    Invoke-ExternalCommand -Command git -Arguments @('-C', $Destination, 'fetch', '--depth', '1', 'origin', $SourceRef)
    Invoke-ExternalCommand -Command git -Arguments @('-C', $Destination, 'checkout', '--detach', 'FETCH_HEAD')
}

foreach ($command in @('docker', 'git')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required but was not found."
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Get-Repository -Repository $FrontendRepository -Destination $frontendSource
    Get-Repository -Repository $BackendRepository -Destination $backendSource

    $frontendPatch = Join-Path $repositoryRoot 'containers/frontend/source.patch'
    Invoke-ExternalCommand -Command git -Arguments @('-C', $frontendSource, 'apply', '--check', $frontendPatch)
    Invoke-ExternalCommand -Command git -Arguments @('-C', $frontendSource, 'apply', $frontendPatch)
    Copy-Item (Join-Path $repositoryRoot 'containers/frontend/package-lock.json') (Join-Path $frontendSource 'package-lock.json') -Force

    $backendPatch = Join-Path $repositoryRoot 'containers/backend/source.patch'
    Invoke-ExternalCommand -Command git -Arguments @('-C', $backendSource, 'apply', '--check', $backendPatch)
    Invoke-ExternalCommand -Command git -Arguments @('-C', $backendSource, 'apply', $backendPatch)

    $frontendBuild = Join-Path $frontendSource '.migration-build'
    $backendBuild = Join-Path $backendSource '.migration-build'
    New-Item -ItemType Directory -Path $frontendBuild, $backendBuild -Force | Out-Null
    Copy-Item (Join-Path $repositoryRoot 'containers/frontend/*') $frontendBuild -Force
    Copy-Item (Join-Path $repositoryRoot 'containers/backend/*') $backendBuild -Force

    $frontendRevision = (& git -C $frontendSource rev-parse HEAD).Trim()
    $backendRevision = (& git -C $backendSource rev-parse HEAD).Trim()
    $frontendImage = "$RegistryLoginServer/clinical-unit-frontend:$ImageTag"
    $backendImage = "$RegistryLoginServer/clinical-unit-backend:$ImageTag"

    Invoke-ExternalCommand -Command docker -Arguments @(
        'build', '--pull',
        '--platform', $ContainerPlatform,
        '--build-arg', "NPM_REGISTRY=$NpmRegistry",
        '--file', (Join-Path $frontendBuild 'Containerfile'),
        '--label', "org.opencontainers.image.revision=$frontendRevision",
        '--tag', $frontendImage,
        $frontendSource
    )
    Invoke-ExternalCommand -Command docker -Arguments @(
        'build', '--pull',
        '--platform', $ContainerPlatform,
        '--build-arg', "PYTHON_PACKAGE_INDEX=$PythonPackageIndex",
        '--file', (Join-Path $backendBuild 'Containerfile'),
        '--label', "org.opencontainers.image.revision=$backendRevision",
        '--tag', $backendImage,
        $backendSource
    )

    if ($Push) {
        $registryName = $RegistryLoginServer.Split('.')[0]
        Invoke-ExternalCommand -Command az -Arguments @('acr', 'login', '--name', $registryName)
        Invoke-ExternalCommand -Command docker -Arguments @('push', $frontendImage)
        Invoke-ExternalCommand -Command docker -Arguments @('push', $backendImage)
    }

    Write-Output "Frontend image: $frontendImage"
    Write-Output "Backend image:  $backendImage"
    Write-Output "Image tag:      $ImageTag"
    Write-Output "Platform:       $ContainerPlatform"
}
finally {
    if (Test-Path $temporaryRoot) {
        Remove-Item $temporaryRoot -Recurse -Force
    }
}