<div align="center">
  <img src="screenshot.png" width="700"/>

  <h1>🏃‍♂️ GitHub Runners Monitoring</h1>
  
  <p align="center">
    <strong>Real-time monitoring solution for GitHub Actions VNET-injected runners</strong>
  </p>
  <p align="center">
    <a href="#-quickstart">Quickstart</a> •
    <a href="#-key-features">Features</a> •
    <a href="#-alert-rules">Alerts</a> •
    <a href="#%EF%B8%8F-architecture">Architecture</a> •
    <a href="#-installation">Installation</a> •
    <a href="#-api-integrations">API</a>
  </p>
  <p align="center">
    <img alt="Azure" src="https://img.shields.io/badge/azure-ready-0078D4?style=for-the-badge">
    <img alt="Python" src="https://img.shields.io/badge/python-3.11-yellow?style=for-the-badge">
  </p>
</div>

## 🌟 What is GitHub Runners Monitoring?
This project demonstrates real-time monitoring and alerting for GitHub Actions runners using Azure Functions and Log Analytics, enabling you to track runner status, detect offline runners, and monitor VNet IP usage to ensure smooth CI/CD operations. While the data flow has been validated, the actual alerting functionality has not been tested (yet), and deploying to production is at your own risk. If you implement this solution in a production environment and identify any improvements, please feel free to open a Pull Request (PR).

- 📊 **Real-time Monitoring**: Track runner status and VNet usage every 5 minutes
- 🚨 **Alerting**: Get notified when runners go offline or VNet usage exceeds thresholds
- 📈 **Custom Dashboard**: Visual insights into runner health and IP consumption

### API Integrations

#### GitHub Actions API
This solution uses the [GitHub Actions Runners API](https://docs.github.com/en/rest/actions/self-hosted-runners?apiVersion=2022-11-28) to monitor runner status. Example response:

```json
{
    "success": true,
    "message": "All runners online",
    "details": {
        "total_runners": 3,
        "offline_count": 0,
        "runner_statuses": [
            {
                "TimeGenerated": "2025-01-15T13:52:45Z",
                "RunnerId_s": "35",
                "Name_s": "runner_149f511b76f6",
                "Status_s": "online",
                "OS_s": "Ubuntu 22.04.5 LTS",
                "Busy_b": false,
                "Labels_s": "[]",
                "Organization_s": "your-org-name"
            }
        ]
    }
}
```

#### Azure Virtual Network API
This solution uses the [Virtual Networks - List Usage API](https://learn.microsoft.com/en-us/rest/api/virtualnetwork/virtual-networks/list-usage?view=rest-virtualnetwork-2024-05-01) to monitor VNet resource consumption. Example response:

```json
{
    "success": true,
    "message": "All VNet usages are within threshold.",
    "details": {
        "vnet_usages": [
            {
                "TimeGenerated": "2025-01-15T13:58:54.062386Z",
                "SubscriptionId_s": "subscription-id",
                "ResourceGroupName_s": "your-resource-group",
                "VNetName_s": "your-vnet-name",
                "UsageName_s": "SubnetSpace",
                "CurrentValue_d": 1,
                "Limit_d": 251,
                "Unit_s": "Count",
                "UsagePct_d": 0.398406374501992,
                "Type": "VNetUsage_CL"
            }
        ]
    }
}
```

### Required Permissions

#### GitHub API Access
- `admin:org` scope for OAuth tokens
- Organization admin access
- `Self-hosted runners` read permission for fine-grained tokens

#### Azure API Access
- Virtual Network read permissions
- Azure role-based access control (RBAC) permissions:
  - `Microsoft.Network/virtualNetworks/read`
  - `Microsoft.Network/virtualNetworks/usages/read`

## 🚀 Quickstart
1. Replace placeholders in `./scripts/deploy.sh`:
```bash
GITHUB_TOKEN_VALUE="<GITHUB_TOKEN>"
GITHUB_TOKEN_SECRET_NAME="GH-TOKEN"
GITHUB_ORG="<GITHUB_ORG>"
AZURE_TARGET_VNET_NAME="<VNET_NAME>"
AZURE_TARGET_VNET_RG="<VNET_RG>"
ALERT_EMAIL="<EMAIL>"
```

2. Set up required Azure resources:
```bash
./scripts/deploy.sh
```

## ✨ Key Features

### 🔍 Runner Monitoring
- Real-time status tracking of all runners
- Detection of offline runners
- Busy/idle state monitoring
- Runner label and OS tracking

### 📊 VNet Usage Analysis
- IP address consumption tracking
- Usage threshold monitoring
- Historical usage trends

### 📈 Azure Monitor Integration
- Custom Log Analytics tables
- Real-time metrics ingestion
- Pre-built workbook dashboard
- Customizable alerting rules

## 📦 Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/github-runners-monitoring

# Navigate to the project
cd github-runners-monitoring

# Deploy Azure resources
./scripts/deploy.sh all
```

## 🛠️ Usage

### Deploy Individual Components

```bash
# Deploy specific components
./scripts/deploy.sh rg          # Resource Group only
./scripts/deploy.sh storage     # Storage Account only
./scripts/deploy.sh keyvault    # Key Vault only
./scripts/deploy.sh function    # Function App only
./scripts/deploy.sh loganalytics # Log Analytics only
./scripts/deploy.sh alert       # Alert Rules only
```

### Monitor Configuration

The monitoring solution includes:

1. Runner Status Checks (every 5 minutes):
   - Online/Offline status
   - Busy state
   - Label configuration
   - Operating system

2. VNet Usage Monitoring (every 5 minutes):
   - IP address consumption
   - Usage thresholds
   - Historical trends

### Alert Rules

#### Runner Availability Alert
The solution monitors runner availability using a custom Kusto Query Language (KQL) alert:

```kusto
let timeRange = 30m;
let latestData = GHRunnerStatus_CL
| where TimeGenerated > ago(timeRange)
| where Status_s == 'online'
| summarize OnlineCount=dcount(Name_s);
latestData
| where OnlineCount == 0
| project TimeGenerated=now(),
    ['Message']='No online runners found in the last 30 minutes'
```

This alert:
- Checks for online runners in the last 30 minutes
- Triggers if no online runners are found
- Evaluates every 5 minutes
- Has a severity level of 2 (High)
- Auto-mitigates when conditions return to normal

#### VNet Usage Alert
Monitors VNet IP address consumption with this KQL query:

```kusto
VNetUsage_CL 
| where UsagePct_d > 80
| summarize ThresholdCount=count() by bin(TimeGenerated, 5m), VNetName_s, UsageName_s
| where ThresholdCount > 0
```

This alert:
- Triggers when VNet usage exceeds 80%
- Monitors all subnets in the specified VNet
- Evaluates every 5 minutes
- Has a severity level of 2 (High)
- Provides subnet-specific usage details

### Dashboard 

Find the workbook template in the `/workbook` directory

The dashboard provides:
- Real-time runner status overview
- VNet usage trends and metrics
- Historical data analysis
- Customizable time ranges

## ⚙️ Architecture

```
GitHub API <─┐
            Azure Function
VNet API   <─┘   │
                 │
                 ▼
        Log Analytics Workspace
                 │
           ┌─────┴─────┐
           │           │
       Workbook     Alerts
```

## 🔧 Environment Setup

Required environment variables for the Function App:

```bash
# GitHub Configuration
GITHUB_ORG="your-organization"
GITHUB_TOKEN_SECRET_NAME="GH-TOKEN"

# Azure Configuration
AZURE_TARGET_VNET_NAME="your-vnet"
AZURE_TARGET_VNET_RG="your-resourcegroup"
SUBSCRIPTION_ID="your-subscription-id"

# Monitoring Configuration
DATA_COLLECTION_ENDPOINT="your-dce-endpoint"
LOGS_DCR_RULE_ID="your-dcr-id"
LOGS_DCR_STREAM_NAME_RUNNER="Custom-GHRunnerStatus_CL"
LOGS_DCR_STREAM_NAME_VNET="Custom-VNetUsage_CL"
```

## 📚 Additional Resources

- [About Azure private networking for GitHub-hosted runners](https://docs.github.com/en/enterprise-cloud@latest/admin/configuring-settings/configuring-private-networking-for-hosted-compute-products/about-azure-private-networking-for-github-hosted-runners-in-your-enterprise)
- [GitHub Actions Runners API Documentation](https://docs.github.com/en/rest/actions/self-hosted-runners)
- [Azure Virtual Network Documentation](https://docs.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview)
- [Virtual Networks REST API Reference](https://learn.microsoft.com/en-us/rest/api/virtualnetwork/virtual-networks)
- [Azure Virtual Network Quotas and Limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits)