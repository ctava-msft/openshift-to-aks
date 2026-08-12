# Create AKS and Run the Terraform

This runbook creates AKS, builds the Clinical Unit images, and deploys one frontend pod plus one backend pod using the same base manifests as ARO.

Install `kubectl` and `kubelogin` before connecting because local AKS accounts are disabled. Azure CLI can install both with `az aks install-cli` when they are not already available.

## 1. Prepare Azure and Remote State

The Terraform caller needs permission to create resources and role assignments, such as `Owner`, or `Contributor` plus `User Access Administrator`.

```powershell
az login
az account set --subscription '<subscription-id>'

$providers = @(
  'Microsoft.Authorization',
  'Microsoft.CognitiveServices',
  'Microsoft.ContainerRegistry',
  'Microsoft.ContainerService',
  'Microsoft.DocumentDB',
  'Microsoft.ManagedIdentity',
  'Microsoft.Network',
  'Microsoft.OperationalInsights',
  'Microsoft.Storage'
)
$providers | ForEach-Object { az provider register --namespace $_ --wait }

.\scripts\Initialize-TerraformBackend.ps1 `
  -SubscriptionId '<subscription-id>' `
  -StorageAccountName '<globally-unique-storage-name>' `
  -Location 'eastus2'
```

The script grants the signed-in user `Storage Blob Data Contributor`. For CI, pass `-PrincipalObjectId '<service-principal-object-id>' -PrincipalType ServicePrincipal`. Allow several minutes for role propagation before `terraform init`.

## 2. Apply the Shared Foundation

```powershell
Copy-Item terraform/foundation/terraform.tfvars.example terraform/foundation/terraform.tfvars
# Edit subscription, region, tags, and Azure OpenAI model settings.

terraform -chdir=terraform/foundation init `
  -backend-config="$PWD/.backend/foundation.hcl" `
  -reconfigure
terraform -chdir=terraform/foundation validate
terraform -chdir=terraform/foundation plan -out foundation.tfplan
terraform -chdir=terraform/foundation apply foundation.tfplan
```

## 3. Apply AKS

```powershell
Copy-Item terraform/aks/terraform.tfvars.example terraform/aks/terraform.tfvars
```

Populate `resource_group_name`, `container_registry_name`, and `log_analytics_workspace_name` from foundation outputs. Set administrator CIDRs and Entra group object IDs for the target environment.

```powershell
terraform -chdir=terraform/aks init `
  -backend-config="$PWD/.backend/aks.hcl" `
  -reconfigure
terraform -chdir=terraform/aks fmt -check
terraform -chdir=terraform/aks validate
terraform -chdir=terraform/aks plan -out aks.tfplan
terraform -chdir=terraform/aks apply aks.tfplan

$resourceGroup = terraform -chdir=terraform/aks output -raw resource_group_name
$clusterName = terraform -chdir=terraform/aks output -raw cluster_name
az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing
kubectl get nodes
```

## 4. Configure DNS, TLS, and Entra

The managed application-routing controller exposes a public IP:

```powershell
kubectl get service -n app-routing-system
```

Create an `A` record for the application hostname pointing to the controller's external IP. Obtain a certificate for that hostname, then create the TLS secret:

```powershell
kubectl apply -f k8s/base/namespace.yaml
kubectl create secret tls clinical-unit-tls `
  -n clinical-unit `
  --cert '<path-to-fullchain.pem>' `
  --key '<path-to-private-key.pem>'
```

Add `https://<application-hostname>` as a **Single-page application** redirect URI on the Clinical Unit Entra app registration. Preserve existing redirect URIs.

## 5. Build, Push, and Deploy

```powershell
$registry = terraform -chdir=terraform/foundation output -raw container_registry_login_server
$tag = Get-Date -Format 'yyyyMMddHHmmss'
.\scripts\Build-Images.ps1 `
  -RegistryLoginServer $registry `
  -NpmRegistry 'https://registry.npmjs.org/' `
  -PythonPackageIndex 'https://pypi.org/simple/' `
  -ImageTag $tag `
  -Push

.\scripts\Deploy-Workload.ps1 `
  -Platform aks `
  -ImageTag $tag `
  -AksHost '<application-hostname>' `
  -EntraClientId '<clinical-unit-spa-client-id>' `
  -EntraTenantId '<tenant-id>' `
  -ClinicalStaffGroupId '<optional-group-object-id>' `
  -AdminGroupId '<optional-group-object-id>'
```

The image builder targets `linux/amd64`, matching the selected AKS node SKU, even on an ARM64 workstation.

## 6. Verify and Clean Up

```powershell
kubectl get pods,services,ingress -n clinical-unit
kubectl get pods -n clinical-unit -l app.kubernetes.io/part-of=clinical-unit
Invoke-WebRequest 'https://<application-hostname>/healthz'
```

Exactly two active application pods should be present.

Destroy in dependency order:

```powershell
kubectl delete -k k8s/overlays/aks
terraform -chdir=terraform/aks plan -destroy -out aks-destroy.tfplan
terraform -chdir=terraform/aks apply aks-destroy.tfplan
```

Destroy the foundation only after ARO is also removed and retained data is no longer required.

Before production, use private networking, approved egress, Key Vault-backed secrets, dedicated API scopes, multiple replicas, autoscaling, disruption budgets, image signing/scanning, backup testing, and formal clinical-data security review.