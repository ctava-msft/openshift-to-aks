[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('aks', 'aro')]
    [string]$Platform,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')]
    [string]$ImageTag,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$EntraClientId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$EntraTenantId,

    [string]$ClinicalStaffGroupId = '',
    [string]$AdminGroupId = '',
    [string]$AzureDomainHint = '',
    [string]$ApiScope = '',
    [string]$AksHost = '',
    [string]$FoundationDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform/foundation'),
    [string]$AroDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform/aro')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$namespace = 'clinical-unit'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "clinical-unit-deploy-$([guid]::NewGuid().ToString('N'))"
$renderRoot = Join-Path $temporaryRoot 'k8s'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Get-TerraformOutputs {
    param([Parameter(Mandatory)][string]$Directory)

    $json = (& terraform "-chdir=$Directory" output -json | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform outputs from $Directory."
    }
    return $json | ConvertFrom-Json
}

function Write-EnvironmentFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $lines = foreach ($entry in $Values.GetEnumerator() | Sort-Object Key) {
        if ([string]$entry.Value -match '[\r\n]') {
            throw "Environment value for $($entry.Key) contains a newline."
        }
        "$($entry.Key)=$($entry.Value)"
    }
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
}

function Apply-GeneratedResource {
    param(
        [Parameter(Mandatory)][string[]]$CreateArguments
    )

    $manifest = (& kubectl @CreateArguments --dry-run=client -o yaml | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw 'kubectl failed to generate a resource manifest.'
    }
    $manifest | & kubectl apply -f - | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'kubectl failed to apply a generated resource manifest.'
    }
}

foreach ($command in @('kubectl', 'terraform')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required but was not found."
    }
}

if ($Platform -eq 'aks' -and [string]::IsNullOrWhiteSpace($AksHost)) {
    throw 'AksHost is required for AKS because Entra SPA redirects require an HTTPS hostname.'
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Copy-Item (Join-Path $repositoryRoot 'k8s') $renderRoot -Recurse

    $foundation = Get-TerraformOutputs -Directory $FoundationDirectory
    $registryLoginServer = [string]$foundation.container_registry_login_server.value
    $frontendUrl = if ($Platform -eq 'aks') { "https://$AksHost" } else { '' }

    $overlayDirectory = Join-Path $renderRoot "overlays/$Platform"
    $kustomizationPath = Join-Path $overlayDirectory 'kustomization.yaml'
    $kustomization = [System.IO.File]::ReadAllText($kustomizationPath)
    $kustomization = $kustomization.Replace('REGISTRY_PLACEHOLDER', $registryLoginServer).Replace('TAG_PLACEHOLDER', $ImageTag)
    [System.IO.File]::WriteAllText($kustomizationPath, $kustomization, $utf8NoBom)

    if ($Platform -eq 'aks') {
        $ingressPath = Join-Path $overlayDirectory 'ingress.yaml'
        $ingress = [System.IO.File]::ReadAllText($ingressPath).Replace('AKS_HOST_PLACEHOLDER', $AksHost)
        [System.IO.File]::WriteAllText($ingressPath, $ingress, $utf8NoBom)
    }

    Invoke-Checked -Command kubectl -Arguments @('apply', '-f', (Join-Path $renderRoot 'base/namespace.yaml'))

    if ($Platform -eq 'aro') {
        Invoke-Checked -Command kubectl -Arguments @('apply', '-n', $namespace, '-f', (Join-Path $renderRoot 'base/frontend-service.yaml'))
        Invoke-Checked -Command kubectl -Arguments @('apply', '-n', $namespace, '-f', (Join-Path $overlayDirectory 'route.yaml'))
        $routeHost = ''
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $routeHostResult = & kubectl get route clinical-unit -n $namespace -o 'jsonpath={.spec.host}' 2>$null
            $routeHost = if ($null -eq $routeHostResult) { '' } else { ([string]$routeHostResult).Trim() }
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($routeHost)) {
                break
            }
            [System.Threading.Thread]::Sleep(2000)
        }
        if ([string]::IsNullOrWhiteSpace($routeHost)) {
            throw 'OpenShift did not assign a hostname to the clinical-unit route.'
        }
        $frontendUrl = "https://$routeHost"
    }

    $frontendConfigPath = Join-Path $temporaryRoot 'frontend.env'
    Write-EnvironmentFile -Path $frontendConfigPath -Values @{
        VITE_ADMIN_GROUP_ID          = $AdminGroupId
        VITE_API_SCOPE               = $ApiScope
        VITE_AZURE_AUTHORITY         = "https://login.microsoftonline.com/$EntraTenantId"
        VITE_AZURE_CLIENT_ID         = $EntraClientId
        VITE_AZURE_DOMAIN_HINT       = $AzureDomainHint
        VITE_AZURE_REDIRECT_URI      = $frontendUrl
        VITE_AZURE_TENANT_ID         = $EntraTenantId
        VITE_CLINICAL_STAFF_GROUP_ID = $ClinicalStaffGroupId
    }
    Apply-GeneratedResource -CreateArguments @(
        'create', 'configmap', 'clinical-unit-frontend', '-n', $namespace,
        "--from-env-file=$frontendConfigPath"
    )

    $backendConfigPath = Join-Path $temporaryRoot 'backend.env'
    Write-EnvironmentFile -Path $backendConfigPath -Values @{
        AZURE_CLIENT_ID                = $EntraClientId
        AZURE_OPENAI_API_VERSION       = [string]$foundation.azure_openai_api_version.value
        AZURE_OPENAI_DEPLOYMENT_NAME   = [string]$foundation.azure_openai_deployment_name.value
        AZURE_OPENAI_ENDPOINT          = [string]$foundation.azure_openai_endpoint.value
        AZURE_TENANT_ID                = $EntraTenantId
        COSMOSDB_COLLECTION            = [string]$foundation.cosmosdb_collection.value
        COSMOSDB_DATABASE              = [string]$foundation.cosmosdb_database.value
        COSMOSDB_HOST                  = [string]$foundation.cosmosdb_host.value
        COSMOSDB_OPTIONS               = [string]$foundation.cosmosdb_options.value
        COSMOSDB_USERNAME              = [string]$foundation.cosmosdb_username.value
        DEVELOPMENT_MODE               = 'false'
        PYTHONDONTWRITEBYTECODE        = '1'
        REQUIRE_DATABASE               = 'true'
    }
    Apply-GeneratedResource -CreateArguments @(
        'create', 'configmap', 'clinical-unit-backend', '-n', $namespace,
        "--from-env-file=$backendConfigPath"
    )

    $backendSecretPath = Join-Path $temporaryRoot 'backend-secret.env'
    Write-EnvironmentFile -Path $backendSecretPath -Values @{
        AZURE_OPENAI_API_KEY = [string]$foundation.azure_openai_key.value
        AZURE_OPENAI_KEY     = [string]$foundation.azure_openai_key.value
        COSMOSDB_PASSWORD    = [string]$foundation.cosmosdb_password.value
    }
    Apply-GeneratedResource -CreateArguments @(
        'create', 'secret', 'generic', 'clinical-unit-backend', '-n', $namespace,
        "--from-env-file=$backendSecretPath"
    )

    if ($Platform -eq 'aro') {
        $aro = Get-TerraformOutputs -Directory $AroDirectory
        $clientId = [string]$aro.service_principal_client_id.value
        $clientSecret = [string]$aro.service_principal_client_secret.value
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${clientId}:${clientSecret}"))
        $dockerConfig = @{
            auths = @{
                $registryLoginServer = @{
                    auth     = $auth
                    password = $clientSecret
                    username = $clientId
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress
        $dockerConfigPath = Join-Path $temporaryRoot '.dockerconfigjson'
        [System.IO.File]::WriteAllText($dockerConfigPath, $dockerConfig, $utf8NoBom)
        Apply-GeneratedResource -CreateArguments @(
            'create', 'secret', 'generic', 'acr-pull', '-n', $namespace,
            '--type=kubernetes.io/dockerconfigjson', "--from-file=.dockerconfigjson=$dockerConfigPath"
        )
    }
    else {
        & kubectl get secret clinical-unit-tls -n $namespace *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Create the clinical-unit-tls secret in the clinical-unit namespace before deploying to AKS.'
        }
    }

    Invoke-Checked -Command kubectl -Arguments @('apply', '-k', $overlayDirectory)
    Invoke-Checked -Command kubectl -Arguments @('rollout', 'status', 'deployment/clinical-unit-backend', '-n', $namespace, '--timeout=5m')
    Invoke-Checked -Command kubectl -Arguments @('rollout', 'status', 'deployment/clinical-unit-frontend', '-n', $namespace, '--timeout=5m')

    $pods = (& kubectl get pods -n $namespace -l app.kubernetes.io/part-of=clinical-unit -o json | Out-String) | ConvertFrom-Json
    $activePods = @($pods.items | Where-Object {
            $deletionTimestamp = $_.metadata.PSObject.Properties['deletionTimestamp']
            $null -eq $deletionTimestamp -or $null -eq $deletionTimestamp.Value
        })
    if ($activePods.Count -ne 2) {
        throw "Expected exactly two active application pods, found $($activePods.Count)."
    }

    Write-Output "Clinical Unit deployed to $Platform with two application pods."
    Write-Output "Application URL: $frontendUrl"
    Write-Output "Add this SPA redirect URI to the Entra app registration: $frontendUrl"
}
finally {
    if (Test-Path $temporaryRoot) {
        Remove-Item $temporaryRoot -Recurse -Force
    }
}