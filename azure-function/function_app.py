import datetime
import logging
import os
import time
import json

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
import requests
from opencensus.ext.azure.log_exporter import AzureLogHandler
from azure.monitor.ingestion import LogsIngestionClient

app = func.FunctionApp()

def setup_logging():
    connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if connection_string:
        custom_logger = logging.getLogger('github_runners')
        custom_logger.setLevel(logging.INFO)
        handler = AzureLogHandler(connection_string=connection_string)
        handler.setFormatter(logging.Formatter('%(message)s'))
        custom_logger.addHandler(handler)
        return custom_logger
    return logging.getLogger()

def setup_client():
    """Setup the LogsIngestionClient"""
    endpoint = os.environ.get("DATA_COLLECTION_ENDPOINT")
    if not endpoint:
        raise ValueError("DATA_COLLECTION_ENDPOINT environment variable is required")
    
    credential = DefaultAzureCredential()
    return LogsIngestionClient(endpoint=endpoint, credential=credential)

def check_github_runners():
    """Common function to check runners, returns (success, message, details)"""
    logger = setup_logging()
    try:
        required_env_vars = {
            "KEYVAULT_URI": os.environ.get("KEYVAULT_URI"),
            "AZURE_STORAGE_CONNECTION_STRING": os.environ.get("AZURE_STORAGE_CONNECTION_STRING") or os.environ.get("AzureWebJobsStorage"),
            "GITHUB_ORG": os.environ.get("GITHUB_ORG"),
            "GITHUB_TOKEN_SECRET_NAME": os.environ.get("GITHUB_TOKEN_SECRET_NAME")
        }

        storage_source = "AZURE_STORAGE_CONNECTION_STRING" if os.environ.get("AZURE_STORAGE_CONNECTION_STRING") else "AzureWebJobsStorage"
        logging.info(f"Using storage connection from: {storage_source}")
        missing_vars = [k for k, v in required_env_vars.items() if not v]
        if missing_vars:
            return False, f"Missing environment variables: {', '.join(missing_vars)}", None

        credential = DefaultAzureCredential()
        secret_client = SecretClient(vault_url=required_env_vars["KEYVAULT_URI"], credential=credential)
        github_token = secret_client.get_secret(required_env_vars["GITHUB_TOKEN_SECRET_NAME"]).value

        url = f"https://api.github.com/orgs/{required_env_vars['GITHUB_ORG']}/actions/runners"
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {github_token}",
            "X-GitHub-Api-Version": "2022-11-28"
        }
        resp = requests.get(url, headers=headers)
        if resp.status_code != 200:
            return False, f"GitHub API error: {resp.status_code}", None

        runners = resp.json().get("runners", [])
        
        timestamp = int(time.time())
        offline_runners = []
        runner_statuses = []
        current_time = datetime.datetime.utcnow()
        runner_logs = []

        for runner in runners:
            status = runner.get("status", "unknown")
            name = runner.get("name", "unknown")
            current_time = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            runner_data = {
                "TimeGenerated": current_time,
                "RunnerId_s": str(runner.get("id")),
                "Name_s": name,
                "Status_s": status,
                "OS_s": runner.get("os", "unknown"),
                "Busy_b": runner.get("busy", False),
                "Labels_s": json.dumps(runner.get("labels", [])),
                "Organization_s": required_env_vars["GITHUB_ORG"],
                "Computer": os.environ.get("COMPUTERNAME", ""),
                "Type": "GHRunnerStatus_CL"
            }
            
            logger.info("GitHubRunnerStatus", extra={
                "custom_dimensions": runner_data,
                "time": current_time
            })

            runner_statuses.append(runner_data)

            if status.lower() != "online":
                offline_runners.append(name)
                logger.error("OfflineRunnerFound", extra={
                    "custom_dimensions": {
                        "TimeGenerated": current_time,
                        "Name_s": name,
                        "Status_s": status,
                        "Organization_s": required_env_vars["GITHUB_ORG"],
                        "Type": "GHRunnerStatus_CL"
                    },
                    "time": current_time
                })

            log_entry = {
                "TimeGenerated": current_time,
                "RunnerId_s": str(runner.get("id")),
                "Name_s": name,
                "Status_s": status,
                "OS_s": runner.get("os", "unknown"),
                "Busy_b": runner.get("busy", False),
                "Labels_s": json.dumps(runner.get("labels", [])),
                "Organization_s": required_env_vars["GITHUB_ORG"],
                "Computer": os.environ.get("COMPUTERNAME", "")
            }
            
            runner_logs.append(log_entry)

            if status.lower() != "online":
                offline_runners.append(name)
                logging.error(f"OfflineRunnerFound: {name}")

        client = setup_client()
        rule_id = os.environ.get("LOGS_DCR_RULE_ID")
        stream_name = os.environ.get("LOGS_DCR_STREAM_NAME_RUNNER", "Custom-GHRunnerStatus_CL")
        
        def on_error(error):
            logging.error(f"Failed to upload logs: {error.error}")
            logging.error(f"Failed logs: {error.failed_logs}")

        client.upload(
            rule_id=rule_id,
            stream_name=stream_name,
            logs=runner_logs,
            on_error=on_error
        )

        result = {
            "total_runners": len(runners),
            "offline_count": len(offline_runners),
            "runner_statuses": runner_statuses,
            "timestamp": datetime.datetime.utcnow().isoformat()
        }

        if offline_runners:
            offline_str = ", ".join(offline_runners)
            logging.error(f"OfflineRunnerFound: {offline_str}")
            return True, f"Found {len(offline_runners)} offline runners", result
        
        return True, "All runners online", result

    except Exception as e:
        return False, f"Error: {str(e)}", None

def check_vnet_usage(threshold_percentage=80) -> tuple[bool, str, dict]:
    """
    Calls the Virtual Network - List Usage API and checks if any usage is above the given threshold.
    Returns (success, message, details).
    """
    logger = setup_logging()
    try:
        subscription_id = os.environ.get("SUBSCRIPTION_ID")
        resource_group_name = os.environ.get("RESOURCE_GROUP_NAME")
        vnet_name = os.environ.get("VIRTUAL_NETWORK_NAME")
        api_version = os.environ.get("API_VERSION", "2024-05-01")

        required_vars = [("SUBSCRIPTION_ID", subscription_id),
                        ("RESOURCE_GROUP_NAME", resource_group_name),
                        ("VIRTUAL_NETWORK_NAME", vnet_name)]
        missing = [var for var, val in required_vars if not val]
        if missing:
            return (False, f"Missing environment variables: {', '.join(missing)}", {})

        credential = DefaultAzureCredential()
        token = credential.get_token("https://management.azure.com/.default").token

        usage_url = (
            f"https://management.azure.com/"
            f"subscriptions/{subscription_id}/"
            f"resourceGroups/{resource_group_name}/"
            f"providers/Microsoft.Network/"
            f"virtualNetworks/{vnet_name}/usages"
            f"?api-version={api_version}"
        )

        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }
        response = requests.get(usage_url, headers=headers)

        if response.status_code != 200:
            return False, f"VNet Usage API failed with status code {response.status_code}", {}

        usage_data = response.json()
        if "value" not in usage_data:
            return False, "Invalid usage data received.", usage_data

        vnet_usages = usage_data["value"]
        threshold_exceeded = []
        usage_logs = []
        current_time_str = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ")

        for item in vnet_usages:
            name = item["name"]["value"]
            current_value = item["currentValue"]
            limit = item["limit"]
            unit = item.get("unit", "Count")

            usage_pct = (current_value / limit * 100) if limit > 0 else 0

            usage_log_entry = {
                "TimeGenerated": current_time_str,
                "SubscriptionId_s": subscription_id,
                "ResourceGroupName_s": resource_group_name,
                "VNetName_s": vnet_name,
                "UsageName_s": name,
                "CurrentValue_d": current_value,
                "Limit_d": limit,
                "Unit_s": unit,
                "UsagePct_d": usage_pct,
                "Type": "VNetUsage_CL"
            }
            usage_logs.append(usage_log_entry)

            if usage_pct > threshold_percentage:
                threshold_exceeded.append({
                    "name": name,
                    "currentValue": current_value,
                    "limit": limit,
                    "usagePct": usage_pct
                })

        for entry in usage_logs:
            logger.info("VNetUsage", extra={"custom_dimensions": entry})

        try:
            client = setup_client()
            rule_id = os.environ.get("LOGS_DCR_RULE_ID")
            stream_name = os.environ.get("LOGS_DCR_STREAM_NAME_VNET", "Custom-VNetUsage_CL")

            if rule_id and stream_name:
                def on_error(error):
                    logging.error(f"Failed to upload VNet usage logs: {error.error}")
                    logging.error(f"Failed logs: {error.failed_logs}")

                client.upload(
                    rule_id=rule_id,
                    stream_name=stream_name,
                    logs=usage_logs,
                    on_error=on_error
                )
        except Exception as e:
            logging.error(f"Failed to send logs to Log Analytics: {str(e)}")

        if threshold_exceeded:
            message = f"Threshold exceeded for {len(threshold_exceeded)} usage(s)."
            logger.error(message, extra={"custom_dimensions": {"threshold_exceeded": threshold_exceeded}})
            return (True, message, {"threshold_exceeded": threshold_exceeded})
        
        return (True, "All VNet usages are within threshold.", {"vnet_usages": usage_logs})

    except Exception as e:
        return False, f"Error in check_vnet_usage: {str(e)}", {}

@app.route(route="runners/status", auth_level=func.AuthLevel.FUNCTION)
def http_check_runners(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('HTTP trigger function processed a request.')
    
    success, message, details = check_github_runners()
    
    status_code = 200 if success else 500
    response_body = {
        "success": success,
        "message": message,
        "details": details
    }
    
    return func.HttpResponse(
        body=json.dumps(response_body),
        mimetype="application/json",
        status_code=status_code
    )

@app.route(route="vnet/usage", auth_level=func.AuthLevel.FUNCTION)
def http_check_vnet_usage(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("HTTP trigger function for VNet Usage called.")
    
    threshold = req.params.get("threshold")
    try:
        threshold_pct = float(threshold) if threshold else 80
    except ValueError:
        return func.HttpResponse(
            "Invalid threshold parameter",
            status_code=400
        )
    
    print ('\033[91m' + f"Checking VNet usage with threshold: {threshold_pct}" + '\033[0m')
    success, message, details = check_vnet_usage(threshold_percentage=threshold_pct)
    
    response_body = {
        "success": success,
        "message": message,
        "details": details
    }
    print (response_body)
    return func.HttpResponse(
        body=json.dumps(response_body),
        mimetype="application/json",
        status_code=200 if success else 500
    )

@app.schedule(schedule="0 */5 * * * *", arg_name="mytimer", run_on_startup=True)
def timer_check_runners(mytimer: func.TimerRequest) -> None:
    if mytimer.past_due:
        logging.info('The timer is past due!')
    
    utc_timestamp = datetime.datetime.utcnow().isoformat()
    logging.info(f"Timer trigger function executed at: {utc_timestamp}")
    
    success, message, _ = check_github_runners()
    if not success:
        logging.error(message)

@app.schedule(schedule="0 */5 * * * *", arg_name="mytimervnet", run_on_startup=True)
def timer_check_vnet_usage(mytimervnet: func.TimerRequest) -> None:
    if mytimervnet.past_due:
        logging.info('The VNet usage timer is past due!')
    
    utc_timestamp = datetime.datetime.utcnow().isoformat()
    logging.info(f"Timer trigger for VNet Usage executed at: {utc_timestamp}")
    
    success, message, details = check_vnet_usage(threshold_percentage=80)
    if not success:
        logging.error(f"VNet usage check failed: {message}")
    else:
        logging.info(f"VNet usage check success: {message}")
