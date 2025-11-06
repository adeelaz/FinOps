# Define tenants to process (each with an ID and Name)
$tenants = @(
    @{ Id = "Tenant1 ID"; Name = "Tenant1 Name" },
    @{ Id = "Tenant2 ID"; Name = "Tenant2 Name" }
)

# Path to store historical backup inventory data
$outputPath = "C:\Temp\AllBackupInventory_History.csv"
$today = Get-Date

# Initialize results array
$results = @()
$tenantCount = $tenants.Count
$tenantIndex = 1

# Loop through each tenant
foreach ($tenant in $tenants) {
    Write-Host "`n[$tenantIndex/$tenantCount] Connecting to tenant: $($tenant.Name) ($($tenant.Id))" -ForegroundColor Cyan
    Connect-AzAccount -Tenant $tenant.Id | Out-Null
    
    # Get all subscriptions for this tenant
    # Note: The Where-Object filter is useful when Azure Lighthouse is in play; otherwise, it doesn't affect results
    $subscriptions = Get-AzSubscription -TenantId $tenant.Id | Where-Object { $_.TenantId -eq $_.HomeTenantId }
    $subCount = $subscriptions.Count
    $subIndex = 1

    # Loop through each subscription in tenant
    foreach ($sub in $subscriptions) {
        Write-Host "  [$subIndex/$subCount] Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Yellow
        Set-AzContext -SubscriptionId $sub.Id -TenantId $tenant.Id | Out-Null
        $context = Get-AzContext

        # Define backup management types and workloads to check
        $combinations = @(
            @{ BMT = "MAB"; Workload = "FileFolder" },
            @{ BMT = "AzureWorkload"; Workload = "MSSQL" },
            @{ BMT = "AzureWorkload"; Workload = "SAPHanaDatabase" },
            @{ BMT = "AzureStorage"; Workload = "AzureFiles" },
            @{ BMT = "AzureSQL"; Workload = "AzureSQLDatabase" },
            @{ BMT = "AzureVM"; Workload = "AzureVM" }
        )

        # Get all Recovery Services vaults in this subscription
        $vaults = Get-AzRecoveryServicesVault
        $vaultCount = $vaults.Count
        $vaultIndex = 1

        # Loop through each vault in the subscription
        foreach ($vault in $vaults) {
            Write-Host "    [$vaultIndex/$vaultCount] Vault: $($vault.Name)" -ForegroundColor Green
            Set-AzRecoveryServicesVaultContext -Vault $vault

            # Loop through each backup management type/workload combination
            foreach ($combo in $combinations) {
                try {
                    $items = Get-AzRecoveryServicesBackupItem -BackupManagementType $combo.BMT -WorkloadType $combo.Workload
                    $itemCount = $items.Count
                    $itemIndex = 1

                    foreach ($item in $items) {
                        Write-Host "      [$itemIndex/$itemCount] Item: $($item.FriendlyName)" -ForegroundColor Gray
                        $itemIndex++
                        
                        # Normalize server name from container string
                        $rawContainer = $item.ContainerName
                        $normalizedServerName = switch ($combo.BMT) {
                            "AzureVM"       { ($rawContainer -split ";")[-1].Trim() }
                            "AzureStorage"  { ($rawContainer -split ";")[-1].Trim() }
                            "AzureWorkload" { ($rawContainer -split ";")[-1].Trim() }
                            default         { $rawContainer.Trim() }
                        }

                        # Try to get backup size from the latest completed backup job
                        $sizeGB = $null
                        $job = Get-AzRecoveryServicesBackupJob |
                            Where-Object {
                                $_.Status -eq "Completed" -and
                                $_.Operation -eq "Backup" -and
                                $_.WorkloadName -eq $normalizedServerName
                            } |
                            Sort-Object StartTime -Descending |
                            Select-Object -First 1

                        if ($job) {
                            try {
                                $jobDetail = Get-AzRecoveryServicesBackupJobDetail -Job $job
                                $sizeMBRaw = $jobDetail.Properties['Backup Size']
                                if ($sizeMBRaw -match "^\d+") {
                                    $sizeMB = ($sizeMBRaw -replace "[^\d]", "")
                                    $sizeGB = [math]::Round([int]$sizeMB / 1024, 2)
                                }
                            } catch {
                                Write-Warning "        Failed to retrieve job detail for item $($item.FriendlyName)"
                            }
                        }

                        # Extract resource group name from SourceResourceId
                        $resourceGroupName = if ($item.SourceResourceId -match "/resourceGroups/([^/]+)") { $matches[1] } else { "" }

                        # Add collected data to results
                        $results += [PSCustomObject]@{
                            DateCollected       = $today.ToString("yyyy-MM-dd")
                            TenantName          = $tenant.Name
                            TenantId            = $tenant.Id
                            SubscriptionName    = $context.Subscription.Name
                            SubscriptionId      = $context.Subscription.Id
                            VaultName           = $vault.Name
                            BackupType          = $combo.BMT
                            WorkloadType        = $combo.Workload
                            ServerName          = $normalizedServerName
                            FriendlyName        = $item.FriendlyName
                            LastBackupTime      = $item.LastBackupTime
                            LatestRecoveryPoint = $item.LatestRecoveryPoint
                            BackupSizeGB        = $sizeGB
                            BackupStatus        = $item.ProtectionStatus
                            BackupState         = $item.ProtectionState
                            LastBackupStatus    = $item.LastBackupStatus                    
                            PolicyName          = $item.ProtectionPolicyName
                            DeleteState         = $item.DeleteState
                            DateOfPurge         = $item.DateOfPurge
                            SourceResourceId    = $item.SourceResourceId
                            ResourceGroupName   = $resourceGroupName

                        }
                    }
                } catch {
                    Write-Warning "      No items found for $($combo.BMT) / $($combo.Workload) in vault $($vault.Name)"
                }
            }
            $vaultIndex++
        }
        $subIndex++
    }
    $tenantIndex++
}

# Append to CSV with UTF-8 encoding
$csvData = $results | ConvertTo-Csv -NoTypeInformation
$csvData | Out-File -FilePath $outputPath -Encoding UTF8 -Append

Write-Host "`n✅ Appended to: $outputPath" -ForegroundColor Cyan
