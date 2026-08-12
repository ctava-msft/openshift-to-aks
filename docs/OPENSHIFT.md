# Create Azure Red Hat OpenShift and Run the Terraform

This runbook creates Azure Red Hat OpenShift (ARO), builds the Clinical Unit images, and deploys one frontend pod plus one backend pod. ARO is the managed OpenShift target used for the OpenShift side of this pilot.

## 1. Confirm Access, Quota, and Cost

The Terraform caller needs:

- permission to create resources and role assignments in the subscription, such as `Owner`, or `Contributor` plus `User Access Administrator`
- permission to create an Entra application and service principal, such as `Application Administrator`
- at least 44 regional DSv5-family vCPUs during creation: an 8-core bootstrap VM, three `Standard_D8s_v5` control-plane nodes, and three `Standard_D4s_v5` workers; 36 cores remain after bootstrap
- Azure OpenAI access and model quota in the foundation region

ARO has a substantial minimum footprint. Review cost and quota before applying.

Sign in and select the subscription:

```powershell
az login
az account set --subscription '<subscription-id>'
az account show --output table
```

Register required resource providers:

```powershell
$providers = @(
  'Microsoft.Authorization',
  'Microsoft.CognitiveServices',
  'Microsoft.Compute',
  'Microsoft.ContainerRegistry',
  'Microsoft.DocumentDB',
  'Microsoft.Network',
  'Microsoft.OperationalInsights',
  'Microsoft.RedHatOpenShift',
  'Microsoft.Storage'
)
$providers | ForEach-Object { az provider register --namespace $_ --wait }
az ad sp create --id 'f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875'
```

Check available OpenShift versions immediately before creating the cluster:

```powershell
az aro get-versions --location eastus2 --output table
```

Use a version returned by this command in `terraform/aro/terraform.tfvars`.

## 2. Create Remote Terraform State

State contains the ARO service-principal secret and application service keys. Do not use local state for a shared deployment.

```powershell
.\scripts\Initialize-TerraformBackend.ps1 `
  -SubscriptionId '<subscription-id>' `
  -StorageAccountName '<globally-unique-storage-name>' `
  -Location 'eastus2'
```

This creates `.backend/foundation.hcl`, `.backend/aks.hcl`, and `.backend/aro.hcl`. The files are ignored by Git and use Entra authentication rather than a storage key.

The script grants the signed-in user `Storage Blob Data Contributor` on the state account. For CI, pass `-PrincipalObjectId '<service-principal-object-id>' -PrincipalType ServicePrincipal`. Grant operators only the required state RBAC and retain blob versioning and soft delete. Role propagation can take several minutes before the first `terraform init`.

## 3. Apply the Shared Foundation

```powershell
Copy-Item terraform/foundation/terraform.tfvars.example terraform/foundation/terraform.tfvars
```

Set the real `subscription_id`, tags, region, and Azure OpenAI model values. Confirm regional model availability and quota; defaults are examples, not a guarantee of capacity.

```powershell
terraform -chdir=terraform/foundation init `
  -backend-config="$PWD/.backend/foundation.hcl" `
  -reconfigure
terraform -chdir=terraform/foundation fmt -check
terraform -chdir=terraform/foundation validate
terraform -chdir=terraform/foundation plan -out foundation.tfplan
terraform -chdir=terraform/foundation apply foundation.tfplan
terraform -chdir=terraform/foundation output
```

Save the resource group and ACR names from the outputs.

## 4. Apply ARO

```powershell
Copy-Item terraform/aro/terraform.tfvars.example terraform/aro/terraform.tfvars
```

Update these required values:

- `subscription_id`
- `resource_group_name` from the foundation output
- `container_registry_name` from the foundation output
- optional `cluster_resource_group_name`; leave null to create a dedicated ARO resource group
- `openshift_version` from `az aro get-versions`
- `cluster_domain`, which must be unique

A Red Hat pull secret is optional for creating ARO but is recommended for entitled content and support. Download it from the Red Hat Hybrid Cloud Console and pass it without adding it to a `.tfvars` file:

```powershell
$env:TF_VAR_redhat_pull_secret = Get-Content -Raw '<path-to-pull-secret.json>'
```

Initialize, inspect, and apply:

```powershell
terraform -chdir=terraform/aro init `
  -backend-config="$PWD/.backend/aro.hcl" `
  -reconfigure
terraform -chdir=terraform/aro fmt -check
terraform -chdir=terraform/aro validate
terraform -chdir=terraform/aro plan -out aro.tfplan
terraform -chdir=terraform/aro apply aro.tfplan
terraform -chdir=terraform/aro output
```

Creation commonly takes 35-60 minutes. The stack creates a dedicated ARO resource group and service principal because one ARO service principal cannot be shared by multiple clusters. Terraform grants it `Contributor` only on the ARO resource group, `Network Contributor` on the VNet, and `AcrPull` on the shared registry.

## 5. Connect to OpenShift

Install `oc` from the OpenShift console download page or Red Hat mirror, then retrieve the initial credentials:

```powershell
$resourceGroup = terraform -chdir=terraform/aro output -raw resource_group_name
$clusterName = terraform -chdir=terraform/aro output -raw cluster_name
$credentials = az aro list-credentials `
  --resource-group $resourceGroup `
  --name $clusterName | ConvertFrom-Json
$apiServer = terraform -chdir=terraform/aro output -raw api_server_url
oc login $apiServer -u $credentials.kubeadminUsername -p $credentials.kubeadminPassword
oc whoami
```

Store the initial password in an approved secret manager, configure Entra-backed OpenShift authentication for operators, and remove routine dependence on `kubeadmin` before production.

## 6. Build and Push the Two Images

The migration Containerfiles run under an arbitrary OpenShift UID and avoid privileged ports. The frontend repository currently lacks a lockfile and has TypeScript errors; this repository applies the reviewed migration patch and lockfile from `containers/frontend` to the ephemeral checkout. The backend patch preserves its required Mongo `_id` shard key during upserts. Upstream both fixes before production.

```powershell
$registry = terraform -chdir=terraform/foundation output -raw container_registry_login_server
$tag = Get-Date -Format 'yyyyMMddHHmmss'
.\scripts\Build-Images.ps1 `
  -RegistryLoginServer $registry `
  -NpmRegistry 'https://registry.npmjs.org/' `
  -PythonPackageIndex 'https://pypi.org/simple/' `
  -ImageTag $tag `
  -Push
```

The script clones the `main` branch of both application repositories, builds the two images, and pushes them to ACR. Pass `-SourceRef '<commit-sha-or-tag>'` for a repeatable release.
It targets `linux/amd64`, matching the selected ARO VM sizes, even on an ARM64 workstation.
On a Microsoft corporate network, the anonymous mirror `https://ms-feed-2.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry/` can be supplied with `-NpmRegistry` if direct public npm is unavailable.
The approved `https://packagefeedproxy.microsoft.io/pypi/simple/` proxy can likewise be supplied with `-PythonPackageIndex` if direct PyPI is unavailable.

## 7. Deploy Exactly Two Pods

Use the client ID of the existing Clinical Unit SPA registration, not the ARO infrastructure service principal:

```powershell
.\scripts\Deploy-Workload.ps1 `
  -Platform aro `
  -ImageTag $tag `
  -EntraClientId '<clinical-unit-spa-client-id>' `
  -EntraTenantId '<tenant-id>' `
  -ClinicalStaffGroupId '<optional-group-object-id>' `
  -AdminGroupId '<optional-group-object-id>'
```

The script:

1. creates the project and OpenShift Route
2. discovers the generated HTTPS route hostname
3. creates frontend and backend configuration
4. creates namespace-scoped backend and ACR pull secrets without printing them
5. applies the portable manifests
6. waits for both Deployments and verifies exactly two active application pods

Add the printed HTTPS URL as a **Single-page application** redirect URI on the Entra app registration. Preserve its existing redirect URIs.

## 8. Verify

```powershell
oc get pods,services,routes -n clinical-unit
oc get pods -n clinical-unit `
  -l app.kubernetes.io/part-of=clinical-unit `
  --field-selector=status.phase=Running
$hostName = oc get route clinical-unit -n clinical-unit -o jsonpath='{.spec.host}'
Invoke-WebRequest "https://$hostName/healthz"
```

Expected application pods:

```text
clinical-unit-frontend-...   1/1   Running
clinical-unit-backend-...    1/1   Running
```

Use `oc logs deployment/clinical-unit-backend -n clinical-unit` for API startup failures and `oc describe pod -n clinical-unit <pod>` for image-pull or security-context failures.

## 9. Destroy the Pilot

Delete the workload, then ARO. Destroy the foundation only after AKS is also removed and no shared data is required.

```powershell
kubectl delete -k k8s/overlays/aro
terraform -chdir=terraform/aro plan -destroy -out aro-destroy.tfplan
terraform -chdir=terraform/aro apply aro-destroy.tfplan
Remove-Item Env:TF_VAR_redhat_pull_secret -ErrorAction SilentlyContinue
```

Optional shared-foundation cleanup:

```powershell
terraform -chdir=terraform/foundation plan -destroy -out foundation-destroy.tfplan
terraform -chdir=terraform/foundation apply foundation-destroy.tfplan
```

Verify that the ARO managed resource group was removed. Retain or archive state according to organizational policy.

## Production Gaps

Before handling production clinical data, add private API/ingress, private endpoints, approved egress, enterprise DNS and certificates, Key Vault-backed secrets, centralized audit retention, image signing/scanning, multiple replicas, disruption budgets, autoscaling, backup/restore tests, Entra API scopes, and formal cutover/rollback ownership. Complete HIPAA and organizational security reviews; this pilot is not a compliance attestation.