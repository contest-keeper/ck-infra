#!/usr/bin/env bash
# One-time setup for deploying Keeper Hub to Azure. Run it yourself, signed in with `az login`, in
# the subscription that will hold the Hub. It makes:
#
#   - the resource group rg-ckhub for the environment (the subscription says which one it is) and one
#     for the Terraform state;
#   - a storage account for the state (no public access, no shared keys, versioned), with one container
#     per environment, so an environment's identity can only reach its own state;
#   - per environment, an Entra application that GitHub Actions signs in as through OIDC. There is
#     NO client secret and nothing to rotate: GitHub proves who it is with a short-lived token, and
#     Azure only accepts it for that environment of the listed repositories. Each application has
#     rights on its own resource group only, so a develop deploy can never touch production.
#
# It prints the values to set as GitHub variables. They are identifiers, not secrets.
# Safe to run twice: what exists is reused.
#
# Usage: bash bootstrap.sh <develop|production> <location> [github-owner]
# Each environment has its own Azure subscription (contest-keeper-dev, contest-keeper-prod): run this once per
# subscription, with that subscription selected (`az account set`), and name its environment.
set -euo pipefail
# Git Bash on Windows would rewrite arguments that start with /subscriptions/ into Windows paths.
export MSYS_NO_PATHCONV=1

# Guard: an environment named by mistake would put its resources and roles in the wrong subscription.
case "${1:-}" in
  develop | production) environments=("$1") ;;
  *) echo "Usage: bash bootstrap.sh <develop|production> <location> [github-owner]" >&2; exit 1 ;;
esac
location="${2:?Give the region, for example germanywestcentral: a new subscription may not accept every region}"
owner="${3:-contest-keeper}"
# The repositories whose workflows deploy: ck-hub after its builds and releases, ck-infra by hand.
repos=("ck-hub" "ck-infra")
# Reusable workflows read the variables and sign in as the repository that calls them: the website and Forge call the
# develop deploy and publish workflows too.
deploy_repos=("${repos[@]}")
[[ "${1:-}" == develop ]] && deploy_repos+=("ck-forge" "ck-website")
state_group="rg-ckhub-tfstate"
# The subscription is the environment, so the group has the same name in each (must match variables.tf).
env_group="rg-ckhub"

subscription_id=$(az account show --query id -o tsv)
tenant_id=$(az account show --query tenantId -o tsv)
echo "Subscription: $(az account show --query name -o tsv) ($subscription_id)"
read -r -p "Set up Keeper Hub (${environments[0]}) in this subscription? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Stopped."; exit 1; }

# Resource providers are registered here, once, because the identities GitHub signs in as have no
# rights outside their resource group (the Terraform provider is told not to register them).
for namespace in Microsoft.App Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.OperationalInsights \
  Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Authorization Microsoft.Network Microsoft.Communication; do
  az provider register --namespace "$namespace" --wait
done

az group create --name "$state_group" --location "$location" --output none
for environment in "${environments[@]}"; do
  az group create --name "$env_group" --location "$location" --output none
done

# The state account name must be globally unique: keep the one made earlier, if there is one.
storage_account=$(az storage account list --resource-group "$state_group" --query "[0].name" -o tsv)
if [[ -z "$storage_account" ]]; then
  storage_account="ckhubtf$(head -c 100 /dev/urandom | tr -dc 'a-z0-9' | head -c 10)"
  az storage account create --name "$storage_account" --resource-group "$state_group" \
    --location "$location" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false \
    --output none
  az storage account blob-service-properties update --account-name "$storage_account" \
    --resource-group "$state_group" --enable-versioning true --output none
fi
storage_id=$(az storage account show --name "$storage_account" --resource-group "$state_group" --query id -o tsv)
state_group_id=$(az group show --name "$state_group" --query id -o tsv)

# Your own account needs the blob role to make the container (the shared key is off).
me=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$storage_id" --output none
echo "Waiting for the role to apply..."
sleep 45
# One state container per environment. Each identity gets its role on its own container only (below), so a
# develop deploy can neither read nor change the production state (which holds the database password).
for environment in "${environments[@]}"; do
  az storage container create --name "tfstate-${environment}" --account-name "$storage_account" \
    --auth-mode login --output none
done

# The roles the identities may hand out (Terraform gives them to the Hub and to the deployer). The
# Role Based Access Control Administrator role is limited to these by a condition, so a stolen identity
# cannot make itself Owner.
assignable_ids=""
for role in "Key Vault Secrets Officer" "Key Vault Secrets User" "Storage Blob Delegator" \
  "Storage Blob Data Reader" "Storage Blob Data Contributor"; do
  id=$(az role definition list --name "$role" --query "[0].name" -o tsv)
  [[ -n "$id" ]] || { echo "Role not found: $role" >&2; exit 1; }
  assignable_ids="${assignable_ids:+$assignable_ids, }$id"
done
write_ok="!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${assignable_ids}})"
delete_ok="!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${assignable_ids}})"
rbac_condition="((${write_ok})) AND ((${delete_ok}))"

# One identity per environment.
owner_id=$(gh api "orgs/${owner}" --jq .id)
declare -A client_ids
for environment in "${environments[@]}"; do
  app_name="ck-hub-deploy-${environment}"
  client_id=$(az ad app list --display-name "$app_name" --query "[0].appId" -o tsv)
  if [[ -z "$client_id" ]]; then
    client_id=$(az ad app create --display-name "$app_name" --query appId -o tsv)
  fi
  if [[ -z "$(az ad sp list --filter "appId eq '$client_id'" --query "[0].id" -o tsv)" ]]; then
    az ad sp create --id "$client_id" --output none
  fi
  principal_id=$(az ad sp show --id "$client_id" --query id -o tsv)

  # Azure accepts a GitHub token only for this environment of these repositories. This organization's tokens carry the
  # owner and repository ids in the subject (customised OIDC claims), so the credential is made for that form as well as
  # for the plain one: without it the login stops with AADSTS700213 "No matching federated identity record".
  for repo in "${deploy_repos[@]}"; do
    repo_id=$(gh api "repos/${owner}/${repo}" --jq .id)
    subjects=("repo:${owner}/${repo}:environment:${environment}"       "repo:${owner}@${owner_id}/${repo}@${repo_id}:environment:${environment}")
    for index in 0 1; do
      subject="${subjects[$index]}"
      if [[ -z "$(az ad app federated-credential list --id "$client_id" --query "[?subject=='$subject'].name" -o tsv)" ]]; then
        az ad app federated-credential create --id "$client_id" --parameters "{
          \"name\": \"github-${repo}-${environment}-${index}\",
          \"issuer\": \"https://token.actions.githubusercontent.com\",
          \"subject\": \"${subject}\",
          \"audiences\": [\"api://AzureADTokenExchange\"]
        }" --output none
      fi
    done
  done

  # Rights on this environment's resource group only. "Role Based Access Control Administrator"
  # lets Terraform give the Hub's managed identity its roles (read secrets in the Key Vault, sign
  # storage links, read and write its two containers); the condition above limits it to those roles, and
  # it cannot reach anything outside the group. "Storage Blob Data Contributor" lets the publish and
  # website workflows upload with the identity (no storage account key) to the accounts in the group.
  group_id=$(az group show --name "$env_group" --query id -o tsv)
  for role in "Contributor" "Storage Blob Data Contributor"; do
    az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$group_id" --output none
  done
  # An assignment made before the condition existed is replaced, so a re-run tightens it.
  # shellcheck disable=SC2046 # ids from tsv have no spaces
  for old in $(az role assignment list --assignee "$principal_id" --scope "$group_id" \
    --role "Role Based Access Control Administrator" --query "[?scope=='$group_id'].id" -o tsv); do
    az role assignment delete --ids "$old" --output none
  done
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "Role Based Access Control Administrator" --scope "$group_id" \
    --condition "$rbac_condition" --condition-version "2.0" --output none
  # The state of this environment only: its own container, not the whole state account.
  state_container_id="${storage_id}/blobServices/default/containers/tfstate-${environment}"
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$state_container_id" --output none
  # Terraform looks the state account up through its resource group before it reads the blob.
  az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
    --role "Reader" --scope "$state_group_id" --output none
  # Set REMOVE_OLD_STATE_ROLE=1 once the state has moved to tfstate-<environment> (see the migration steps): drops the
  # old role on the whole account, which let this identity reach the other environment's state.
  if [[ "${REMOVE_OLD_STATE_ROLE:-0}" == 1 ]]; then
    # shellcheck disable=SC2046 # ids from tsv have no spaces
    for old in $(az role assignment list --assignee "$principal_id" --scope "$storage_id" \
      --role "Storage Blob Data Contributor" --query "[?scope=='$storage_id'].id" -o tsv); do
      az role assignment delete --ids "$old" --output none
    done
  fi
  client_ids[$environment]="$client_id"
done

cat <<EOF

Done. Set these as GitHub variables (identifiers, not secrets). The tenant and the client ids are the
same for every subscription, so they are organization variables. The subscription and the state account
differ per environment, so they are variables of the ${environments[0]} environment in each repository
(an environment variable wins over an organization one of the same name):

  gh variable set AZURE_TENANT_ID                       --org ${owner} --visibility all --body "${tenant_id}"
  gh variable set AZURE_CLIENT_ID_${environments[0]^^}  --org ${owner} --visibility all --body "${client_ids[${environments[0]}]}"
EOF
for repo in "${deploy_repos[@]}"; do
  cat <<EOF
  gh api -X PUT repos/${owner}/${repo}/environments/${environments[0]} --silent
  gh variable set AZURE_SUBSCRIPTION_ID  --repo ${owner}/${repo} --env ${environments[0]} --body "${subscription_id}"
  gh variable set TFSTATE_RESOURCE_GROUP --repo ${owner}/${repo} --env ${environments[0]} --body "${state_group}"
  gh variable set TFSTATE_STORAGE        --repo ${owner}/${repo} --env ${environments[0]} --body "${storage_account}"
EOF
done
cat <<EOF

Remove the old organization variables AZURE_SUBSCRIPTION_ID, TFSTATE_RESOURCE_GROUP and TFSTATE_STORAGE, so no
environment can fall back to another subscription. Then, in each of ${repos[*]} (Settings > Environments),
set the rules of ${environments[0]}. Production: add yourself as a required reviewer and allow deployments from
the main branch only. Develop: allow the develop branch only. See docs/azure.md.

For a deploy from your own PC, copy backend.hcl.example to backend.hcl with the same state values.
EOF
