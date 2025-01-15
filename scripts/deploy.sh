#!/usr/bin/env bash
set -e

# Add usage information
usage() {
    echo "Usage: $0 [component]"
    echo "Components:"
    echo "  all          - Deploy everything (default)"
    echo "  rg           - Resource Group only"
    echo "  storage      - Storage Account only"
    echo "  keyvault     - Key Vault only"
    echo "  function     - Function App only"
    echo "  loganalytics - Log Analytics only"
    echo "  alert        - Alert Rule only"
    exit 1
}

# Get component argument
COMPONENT=${1:-all}

# Validate component
case $COMPONENT in
    all|rg|storage|keyvault|function|loganalytics|alert) ;;
    *) usage ;;
esac

################################################################################
# This script sets up:
#   - Resource Group
#   - Storage Account
#   - Key Vault (for GH PAT, named 'GH-TOKEN')
#   - Python Azure Function (Timer Trigger)
#   - Log Analytics Workspace + Diagnostic Settings
#   - Scheduled Query Alert to email when no online runners are found
################################################################################

# ------------------------------
# User-configurable variables
# ------------------------------
RG_NAME="rg-github-runner-status"
LOCATION="eastus"

# Ensure required extensions are installed
echo "Ensuring required Azure CLI extensions are installed..."
az extension add --name monitor-control-service --only-show-errors

# ------------------------------
# Resource name management
# ------------------------------
CONFIG_DIR="$(dirname "$0")/../.config"
ENV_FILE="$CONFIG_DIR/.env"

mkdir -p "$CONFIG_DIR"

load_or_generate_names() {
    if [ -f "$ENV_FILE" ]; then
        echo "Loading existing resource names..."
        source "$ENV_FILE"
    else
        echo "Generating new resource names..."
        SUFFIX=$(openssl rand -hex 4)
        
        STORAGE_NAME="stghubstatus${SUFFIX}"
        KV_NAME="kv-ghrunner-${SUFFIX}"
        FUNC_APP_NAME="func-ghrunner-${SUFFIX}"
        LA_NAME="law-ghrunner-${SUFFIX}"
        DCE_NAME="dceghrunner"
        DCR_NAME="dcrghrunner"
        
        cat > "$ENV_FILE" << EOF
STORAGE_NAME=$STORAGE_NAME
KV_NAME=$KV_NAME
FUNC_APP_NAME=$FUNC_APP_NAME
LA_NAME=$LA_NAME
DCE_NAME=$DCE_NAME
DCR_NAME=$DCR_NAME
EOF
        echo "Resource names saved to $ENV_FILE"
    fi
}

load_or_generate_names

ALERT_NAME="OfflineRunnersAlert"
AG_NAME="OfflineRunnersActionGroup"
SUB_ID=$(az account show --query id -o tsv)

# Replace with your actual values
GITHUB_TOKEN_VALUE="<GITHUB_TOKEN>"
GITHUB_TOKEN_SECRET_NAME="GH-TOKEN"
GITHUB_ORG="<GITHUB_ORG>"
AZURE_TARGET_VNET_NAME="<VNET_NAME>"
AZURE_TARGET_VNET_RG="<VNET_RG>"
ALERT_EMAIL="<EMAIL_ADDRESS>"

echo "Using subscription: $SUB_ID"
echo "Resource group: $RG_NAME (location: $LOCATION)"

# ------------------------------------------------------------------------------
# 1. Create Resource Group
# ------------------------------------------------------------------------------
deploy_resource_group() {
    echo "Creating resource group: $RG_NAME ..."
    az group create --name "$RG_NAME" --location "$LOCATION"
}

# ------------------------------------------------------------------------------
# 2. Create Storage Account
# ------------------------------------------------------------------------------
deploy_storage() {
    echo "Creating storage account: $STORAGE_NAME ..."
    az storage account create \
        --name "$STORAGE_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --sku Standard_LRS

    STORAGE_CONN_STR=$(az storage account show-connection-string \
                    --resource-group "$RG_NAME" \
                    --name "$STORAGE_NAME" \
                    --query connectionString -o tsv)
}

# ------------------------------------------------------------------------------
# 3. Create Key Vault & store GH PAT
# ------------------------------------------------------------------------------
deploy_keyvault() {
    # Get current user's Object ID (add this before Key Vault creation)
    CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)

    # Check if Key Vault exists
    if az keyvault show --name "$KV_NAME" --resource-group "$RG_NAME" >/dev/null 2>&1; then
        echo "Key Vault $KV_NAME already exists, skipping creation..."
    else
        echo "Creating Key Vault: $KV_NAME ..."
        az keyvault create \
            --name "$KV_NAME" \
            --resource-group "$RG_NAME" \
            --location "$LOCATION" \
            --enable-rbac-authorization false \
            --administrators "$CURRENT_USER_ID"
    fi

    # Add access policy for current user if not using RBAC (idempotent operation)
    echo "Ensuring access policy for current user..."
    az keyvault set-policy \
        --name "$KV_NAME" \
        --resource-group "$RG_NAME" \
        --object-id "$CURRENT_USER_ID" \
        --secret-permissions get set list delete

    # Continue with storing the secret
    echo "Storing GitHub PAT in Key Vault (secret name: $GITHUB_TOKEN_SECRET_NAME)"
    az keyvault secret set \
    --vault-name "$KV_NAME" \
    --name "$GITHUB_TOKEN_SECRET_NAME" \
    --value "$GITHUB_TOKEN_VALUE"
}

# ------------------------------------------------------------------------------
# 4. Create Python Function App
# ------------------------------------------------------------------------------
deploy_function() {
    echo "Creating Python Function App: $FUNC_APP_NAME ..."
    az functionapp create \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RG_NAME" \
    --flexconsumption-location "$LOCATION" \
    --runtime python \
    --runtime-version "3.11" \
    --functions-version 4 \
    --os-type Linux \
    --storage-account "$STORAGE_NAME"

    # Enable system-assigned managed identity
    echo "Assigning system identity to $FUNC_APP_NAME ..."
    PRINCIPAL_ID=$(az functionapp identity assign \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RG_NAME" \
    --query principalId -o tsv)

    # ------------------------------------------------------------------------------
    # 5. Grant Key Vault permission to the Function App identity
    # ------------------------------------------------------------------------------
    echo "Granting secret GET permission for principalId $PRINCIPAL_ID on $KV_NAME..."
    az keyvault set-policy \
    --name "$KV_NAME" \
    --resource-group "$RG_NAME" \
    --secret-permissions get \
    --object-id "$PRINCIPAL_ID"

    # ------------------------------------------------------------------------------
    # 6. Configure App Settings
    # ------------------------------------------------------------------------------
    echo "Configuring Function App settings ..."
    az functionapp config appsettings set \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RG_NAME" \
    --settings \
    "AZURE_STORAGE_CONNECTION_STRING=$STORAGE_CONN_STR" \
    "KEYVAULT_URI=https://$KV_NAME.vault.azure.net/" \
    "GITHUB_ORG=$GITHUB_ORG" \
    "GITHUB_TOKEN_SECRET_NAME=$GITHUB_TOKEN_SECRET_NAME" \
    "SUBSCRIPTION_ID=$SUB_ID" \
    "RESOURCE_GROUP_NAME=$AZURE_TARGET_VNET_RG" \
    "VIRTUAL_NETWORK_NAME=$AZURE_TARGET_VNET_NAME" \
    "API_VERSION=2024-05-01"

    # ------------------------------------------------------------------------------
    # 7. Deploy the Function code
    # ------------------------------------------------------------------------------
    echo "Publishing Python Function code ..."
    pushd "$(dirname "$0")/../azure-function" > /dev/null

    # If Azure Functions Core Tools is installed
    func azure functionapp publish "$FUNC_APP_NAME" --python

    popd > /dev/null
}

# ------------------------------------------------------------------------------
# 8. Create Log Analytics Workspace
# ------------------------------------------------------------------------------
deploy_loganalytics() {
    echo "Creating Log Analytics Workspace: $LA_NAME ..."
    az monitor log-analytics workspace create \
    --resource-group "$RG_NAME" \
    --workspace-name "$LA_NAME" \
    --location "$LOCATION" \
    --sku "PerGB2018"

    LA_ID=$(az monitor log-analytics workspace show \
    --resource-group "$RG_NAME" \
    --workspace-name "$LA_NAME" \
    --query id -o tsv)

    LA_WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group "$RG_NAME" \
    --workspace-name "$LA_NAME" \
    --query primarySharedKey -o tsv)

    LA_WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "$RG_NAME" \
    --workspace-name "$LA_NAME" \
    --query customerId -o tsv)

    # Get Application Insights instrumentation key
    APP_INSIGHTS_KEY=$(az monitor app-insights component create \
        --app "$FUNC_APP_NAME" \
        --location "$LOCATION" \
        --resource-group "$RG_NAME" \
        --kind web \
        --query instrumentationKey -o tsv)

    # Update Function App settings with properly formatted connection string
    echo "Configuring Application Insights for Function App..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RG_NAME" \
        --settings \
        "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=$APP_INSIGHTS_KEY"

    # Create custom table for GitHub Runner data with correct column format
    echo "Creating custom table for GitHub Runner data..."
    az monitor log-analytics workspace table create \
        --resource-group "$RG_NAME" \
        --workspace-name "$LA_NAME" \
        --name "GHRunnerStatus_CL" \
        --columns TimeGenerated=datetime RunnerId_s=string Name_s=string Status_s=string OS_s=string Busy_b=boolean Labels_s=string Organization_s=string Computer=string \
        --retention-time 30

    # Create custom table for VNet Usage data
    echo "Creating custom table for VNet Usage data..."
    az monitor log-analytics workspace table create \
        --resource-group "$RG_NAME" \
        --workspace-name "$LA_NAME" \
        --name "VNetUsage_CL" \
        --columns TimeGenerated=datetime SubscriptionId_s=string ResourceGroupName_s=string VNetName_s=string UsageName_s=string CurrentValue_d=real Limit_d=real Unit_s=string UsagePct_d=real \
        --retention-time 30

    # Add support for diagnostic settings
    echo "Configuring diagnostic settings..."
    EXISTING_DIAG=$(az monitor diagnostic-settings list \
        --resource "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME/providers/Microsoft.Web/sites/$FUNC_APP_NAME" \
        --query "[?contains(logs[0].category, 'FunctionAppLogs')].name" -o tsv)

    if [ -n "$EXISTING_DIAG" ]; then
        echo "Existing diagnostic setting found: $EXISTING_DIAG. Deleting..."
        az monitor diagnostic-settings delete \
            --name "$EXISTING_DIAG" \
            --resource "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME/providers/Microsoft.Web/sites/$FUNC_APP_NAME"
    fi

    az monitor diagnostic-settings create \
        --name "${FUNC_APP_NAME}-diag" \
        --resource "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME/providers/Microsoft.Web/sites/$FUNC_APP_NAME" \
        --logs '[{"category":"FunctionAppLogs","enabled":true}]' \
        --workspace "$LA_ID"

    # Create Data Collection Endpoint
    echo "Creating Data Collection Endpoint..."
    DCE_IMMUTABLE_ID=$(az monitor data-collection endpoint create \
        --name "$DCE_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --kind "Linux" \
        --public-network-access "Enabled" \
        --query immutableId \
        --output tsv)
    
    echo "Data Collection Endpoint created with ID: $DCE_IMMUTABLE_ID"
    
    LOGS_INGESTION_ENDPOINT=$(az monitor data-collection endpoint show \
        --name "$DCE_NAME" \
        --resource-group "$RG_NAME" \
        --query logsIngestion.endpoint \
        --output tsv)

    echo "Logs Ingestion Endpoint: $LOGS_INGESTION_ENDPOINT"

    DCE_ID=$(az monitor data-collection endpoint show \
        --name "$DCE_NAME" \
        --resource-group "$RG_NAME" \
        --query id \
        --output tsv)

    echo "Data Collection Endpoint ID: $DCE_ID" 

    # Create Data Collection Rule using template
    echo "Creating Data Collection Rule..."
    RULE_FILE="$(dirname "$0")/rule-file.json"
    cp "$(dirname "$0")/rule-file.template.json" "$RULE_FILE"
    
    # Replace placeholders in rule file with full resource IDs
    sed -i.bak "s|##workspaceResourceId##|$LA_ID|g" "$RULE_FILE"
    sed -i.bak "s|##dataCollectionEndpointId##|$DCE_ID|g" "$RULE_FILE"

    echo "Rule file content:"
    cat "$RULE_FILE"

    DCR_IMMUTABLE_ID=$(az monitor data-collection rule create \
        --name "$DCR_NAME" \
        --resource-group "$RG_NAME" \
        --location "$LOCATION" \
        --rule-file "$RULE_FILE" \
        --query immutableId \
        --endpoint-id "$DCE_ID" \
        --output tsv)

    rm -f "$RULE_FILE" "$RULE_FILE.bak"

    # After DCR creation, add role assignment
    echo "Assigning Monitoring Metrics Publisher role to Function App's managed identity..."
    FUNCTION_PRINCIPAL_ID=$(az functionapp identity show \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RG_NAME" \
        --query principalId \
        --output tsv)

    if ! az role assignment create \
        --assignee-object-id "$FUNCTION_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Monitoring Metrics Publisher" \
        --scope "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME/providers/microsoft.insights/datacollectionrules/$DCR_NAME"; then
        echo "Warning: Failed to assign Monitoring Metrics Publisher role. Please assign it manually."
    fi

    # Continue with existing Function App settings update
    echo "Configuring Function App with DCE and DCR settings..."
    az functionapp config appsettings set \
        --name "$FUNC_APP_NAME" \
        --resource-group "$RG_NAME" \
        --settings \
        "DATA_COLLECTION_ENDPOINT=$LOGS_INGESTION_ENDPOINT" \
        "LOGS_DCR_RULE_ID=$DCR_IMMUTABLE_ID" \
        "LOGS_DCR_STREAM_NAME_RUNNER=Custom-GHRunnerStatus_CL" \
        "LOGS_DCR_STREAM_NAME_VNET=Custom-VNetUsage_CL"
}

# ------------------------------------------------------------------------------
# 10. Create an Alert Rule for Offline Runners
# ------------------------------------------------------------------------------
deploy_alert() {
    LA_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RG_NAME" \
        --workspace-name "$LA_NAME" \
        --query id -o tsv)
    
    echo "Log Analytics Workspace ID: $LA_ID"

    # Update alert query for the new LAW data structure
    echo "Creating action group to send email alert..."
    az monitor action-group create \
    --name "$AG_NAME" \
    --short-name "OffRun" \
    --resource-group "$RG_NAME" \
    --action email admin "$ALERT_EMAIL"

    AG_ID=$(az monitor action-group show \
    --name "$AG_NAME" \
    --resource-group "$RG_NAME" \
    --query "id" -o tsv)

    ALERT_QUERY="let timeRange = 30m;
    let latestData = GHRunnerStatus_CL
    | where TimeGenerated > ago(timeRange)
    | where Status_s == 'online'
    | summarize OnlineCount=dcount(Name_s);
    latestData
    | where OnlineCount == 0
    | project
        TimeGenerated=now(),
        ['Message']='No online runners found in the last 30 minutes'"

    echo "Creating scheduled query alert: $ALERT_NAME ..."
    az monitor scheduled-query create \
    --name "$ALERT_NAME" \
    --resource-group "$RG_NAME" \
    --scopes "$LA_ID" \
    --description "Alert when no online runners are found in the last 30 minutes" \
    --action-groups "$AG_ID" \
    --condition "count 'OfflineQuery' > 0" \
    --condition-query "OfflineQuery=$ALERT_QUERY" \
    --evaluation-frequency "5m" \
    --window-size "30m" \
    --severity "2" \
    --auto-mitigate true

    echo "Creating VNet Usage alert rule..."
    VNET_ALERT_NAME="VNetUsageAlert"
    
    # Query for VNet Usage threshold alerts
    VNET_ALERT_QUERY="VNetUsage_CL 
    | where UsagePct_d > 80
    | summarize ThresholdCount=count() by bin(TimeGenerated, 5m), VNetName_s, UsageName_s
    | where ThresholdCount > 0"

    az monitor scheduled-query create \
    --name "$VNET_ALERT_NAME" \
    --resource-group "$RG_NAME" \
    --scopes "$LA_ID" \
    --description "Alert when VNet usage exceeds threshold" \
    --action-groups "$AG_ID" \
    --condition "count 'VNetQuery' > 0" \
    --condition-query "VNetQuery=$VNET_ALERT_QUERY" \
    --evaluation-frequency "5m" \
    --window-size "15m" \
    --severity "2" \
    --auto-mitigate true
}

# Main deployment logic
case $COMPONENT in
    all)
        deploy_resource_group
        deploy_storage
        deploy_keyvault
        deploy_function
        deploy_loganalytics
        deploy_alert
        ;;
    rg) deploy_resource_group ;;
    storage) deploy_storage ;;
    keyvault) deploy_keyvault ;;
    function) deploy_function ;;
    loganalytics) deploy_loganalytics ;;
    alert) deploy_alert ;;
esac

# Show completion message only for full deployment
if [ "$COMPONENT" = "all" ]; then
    cat << 'EOF'
============================================================================
Deployment complete.
============================================================================
How it works:
 - Timer Trigger calls GitHub API every hour
 - If no runner is online, logs an ERROR with 'OfflineRunnerFound'
 - Logs go to Log Analytics. A scheduled query checks for 'OfflineRunnerFound' and sends an email
 - Alerting is already setup, for the Dashboard you can create it via the included workbook template
============================================================================
EOF
else
    echo "Deployed component: $COMPONENT"
fi