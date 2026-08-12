[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    [string]$Location = 'eastus2',
    [string]$ResourceGroupName = 'rg-terraform-state',
    [string]$ContainerName = 'tfstate',
    [string]$PrincipalObjectId = '',
    [ValidateSet('User', 'ServicePrincipal')]
    [string]$PrincipalType = 'User',
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.backend')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and run az login before this script.'
}

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId)
Invoke-AzCli -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--output', 'none')
Invoke-AzCli -Arguments @(
    'storage', 'account', 'create',
    '--name', $StorageAccountName,
    '--resource-group', $ResourceGroupName,
    '--location', $Location,
    '--sku', 'Standard_ZRS',
    '--kind', 'StorageV2',
    '--min-tls-version', 'TLS1_2',
    '--allow-blob-public-access', 'false',
    '--https-only', 'true',
    '--output', 'none'
)
Invoke-AzCli -Arguments @(
    'storage', 'container-rm', 'create',
    '--storage-account', $StorageAccountName,
    '--name', $ContainerName,
    '--public-access', 'off',
    '--output', 'none'
)
Invoke-AzCli -Arguments @(
    'storage', 'account', 'blob-service-properties', 'update',
    '--account-name', $StorageAccountName,
    '--resource-group', $ResourceGroupName,
    '--enable-versioning', 'true',
    '--enable-delete-retention', 'true',
    '--delete-retention-days', '30',
    '--enable-container-delete-retention', 'true',
    '--container-delete-retention-days', '30',
    '--output', 'none'
)

if ([string]::IsNullOrWhiteSpace($PrincipalObjectId)) {
    if ($PrincipalType -ne 'User') {
        throw 'PrincipalObjectId is required when PrincipalType is ServicePrincipal.'
    }
    $PrincipalObjectId = (Invoke-AzCli -Arguments @(
            'ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv'
        ) | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($PrincipalObjectId)) {
    throw 'Unable to determine the Terraform operator object ID.'
}

$storageScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
Invoke-AzCli -Arguments @(
    'role', 'assignment', 'create',
    '--assignee-object-id', $PrincipalObjectId,
    '--assignee-principal-type', $PrincipalType,
    '--role', 'Storage Blob Data Contributor',
    '--scope', $storageScope,
    '--output', 'none'
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($stack in @('foundation', 'aks', 'aro')) {
    $content = @(
        "resource_group_name  = `"$ResourceGroupName`""
        "storage_account_name = `"$StorageAccountName`""
        "container_name       = `"$ContainerName`""
        "key                  = `"$stack.tfstate`""
        "subscription_id      = `"$SubscriptionId`""
        'use_azuread_auth     = true'
    )
    $path = Join-Path $OutputDirectory "$stack.hcl"
    [System.IO.File]::WriteAllLines($path, $content, $utf8NoBom)
}

Write-Output "Terraform backend created. Backend files: $OutputDirectory"