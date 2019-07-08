function Get-NumRelocsRunning
{
	(Get-Task | ?{($_.Name -eq "RelocateVM_Task" -or $_.Name -eq "ApplyStorageDrsRecommendation_Task") -and $_.percentcomplete -lt 100}).Count
}

function Show-RelocateVM
{
	Get-Task | ?{$_.Name -eq "RelocateVM_Task" -or $_.Name -eq "ApplyStorageDrsRecommendation_Task"} | Select @{N="EntityName";E={$_.ExtensionData.Info.EntityName}},PercentComplete,@{N="User";E={$_.ExtensionData.Info.Reason.UserName}}
}

function Get-VMObjects
{
	param (
		[string]$CSVFile,
		[switch]$ComputeOnly
	)
	if($ComputeOnly)
	{
		$vms = Import-Csv $CSVFILE | ?{$_.DestinationHost}
		$vms | %{$_.MemoryGB = [int]$_.MemoryGB}
	}
	else 
	{
		$vms = Import-Csv $CSVFILE | ?{$_.DestinationHost -and $_.DestinationDatastore}
		$vms | %{$_.ProvisionedGB = [int]$_.ProvisionedGB}
	}
	
	return $vms 
}

function Start-Migration
{
	param (
		[string]$CSVFile,
		[switch]$ComputeOnly,
		[switch]$Move,
		[switch]$NoSleep
	)
	
	if($ComputeOnly)
	{ 
		$vms = Get-VMObjects $CSVFile -ComputeOnly
	}
	else {
		$vms = Get-VMObjects $CSVFile
	}
	$moved = 0
	$started = (Get-Date)
	$logfile = "migrations_$(get-date -Format FileDateTime).csv"
	
	Write-Host -NoNewline "$(Get-Date)" -ForegroundColor White
	Write-Host -nonewline " [$($moved.ToString().PadLeft(2))/$($vms.Count)]" -ForegroundColor Cyan 
	Write-Host "`tMigration list has $($vms.count) virtual machines" -ForegroundColor White
	foreach ($vm in $vms)
	{
		do{
			# don't migrate between 6AM and 8:00PM
			if ( (-Not $NoSleep) -and ((get-date) -gt "6:00AM") -and ((get-date) -lt "8:00PM")) 
			{ 
				Write-Host -NoNewline "$(Get-Date)" -ForegroundColor White
				Write-Host -nonewline " [$($moved.ToString().PadLeft(2))/$($vms.Count)]" -ForegroundColor Cyan
				Write-Host "`tSleeping until $(get-date '8:30PM')" -ForegroundColor Yellow

				Start-Sleep -Seconds ((Get-Date "8:30PM") - (get-Date)).TotalSeconds 

				Write-Host -NoNewline "$(Get-Date)" -ForegroundColor White
				Write-Host -nonewline " [$($moved.ToString().PadLeft(2))/$($vms.Count)]" -ForegroundColor Cyan
				Write-Host "$(Get-Date)`t`tResuming migrations" -ForegroundColor Green
			}
			
			if ((Get-NumRelocsRunning) -lt 2) 
			{ 
				$moved++
				Write-Host -nonewline "$(Get-Date) " -ForegroundColor White
				Write-Host -nonewline "[$($moved.ToString().PadLeft(2))/$($vms.Count)]`t" -ForegroundColor Cyan
				if ($ComputeOnly)
				{
					if($Move)
					{
						Move-VirtualMachine -Move -ComputeOnly $vm | Export-Csv -Append -Path $logfile
					}
					else {
						Move-VirtualMachine -ComputeOnly $vm | Export-Csv -Append -Path $logfile
					}
				}
				else {
					if($Move)
					{
						Move-VirtualMachine -Move $vm | Export-Csv -Append -Path $logfile
					}
					else {
						Move-VirtualMachine $vm | Export-Csv -Append -Path $logfile
					}
				}
				$tryagain = $false
			}
			else
			{
				Start-Sleep -Seconds 10
				$tryagain = $true
			}
		} while ($tryagain)
	}

	$finished = (get-Date)
	Write-Host "$(Get-Date)`t`tMoved $moved virtual machines in $($finished - $started)."
}

function Move-VirtualMachine
{
    param(
        [Parameter(Mandatory=$true)]
		[PSCustomObject]$VirtualMachine,
		[switch]$ComputeOnly,
        [switch]$Move
    )
    $vm = Get-Vm $VirtualMachine.Name
    $VMHost = Get-VMHost $VirtualMachine.DestinationHost

    # Check if VM and Host are in same cluster already.
    if ( ($VM | Get-Cluster).Name -match ($VMHost | Get-Cluster).Name )
    {
        Write-Host "VM and Host already in same cluster. Skipping $($VM.Name)." -ForegroundColor Yellow
        return
	}
	
	if ( $VM.ExtensionData.DisabledMethod -contains "RelocateVM_Task")
	{
		Write-Host "RelocateVM_Task disabled for this VM. Skipping $($VM.Name)" -ForegroundColor Yellow
		return
	}

    # need to move network cards to the equivalent distributed protgroup on the cluster.
	$Nics = Get-NetworkAdapter -VM $vm
	$newVDP = @()
	foreach ($nic in $nics)
	{
		# crude, but add necessary name mappings for old portgroup names to new if necessary (hopefully most names match 🤞)
		# if there are a large number of mappings I'd add them to the csv file and modify this block.
		if ($nic.NetworkName -eq "Old-PG-Name")
			{ $newVDP += Get-VDPortGroup "New-PG-Name" }
		elseif ($nic.NetworkName -eq "Old-PG-Name2")
			{ $newVDP += Get-VDPortGroup "New-PG-Name2" }
		else
			{ $newVDP += Get-VDPortGroup $nic.NetworkName }
	}

    if ($Move)
    {
		Write-Host "Queuing $VM" -ForegroundColor Magenta
		if($ComputeOnly)
		{
			$null = Move-VM -VM $VM -Destination $VMHost -VMotionPriority High -NetworkAdapter $Nics -PortGroup $newVDP -RunAsync
			[PSCustomObject]@{VM=$VM.Name
				Queued=(Get-Date)}
		}
		else {
			$null = Move-VM -VM $VM -Destination $VMHost -VMotionPriority High -Datastore $VirtualMachine.DestinationDatastore -DiskStorageFormat EagerZeroedThick -NetworkAdapter $Nics -PortGroup $newVDP -RunAsync
			[PSCustomObject]@{VM=$VM.Name
				Queued=(Get-Date)}
		}
    }
    else
    {
		if($ComputeOnly)
		{
			Write-Host "Move-VM -VM $VM -Destination $VMHost -VMotionPriority High -NetworkAdapter $Nics -PortGroup $newVDP -RunAsync" -ForegroundColor Magenta
			[PSCustomObject]@{VM=$VM.Name
				Queued=(Get-Date)}
		}
		else {
			Write-Host "Move-VM -VM $VM -Destination $VMHost -VMotionPriority High -Datastore $($VirtualMachine.DestinationDatastore) -DiskStorageFormat EagerZeroedThick -NetworkAdapter $Nics -PortGroup $newVDP -RunAsync" -ForegroundColor Magenta
        [PSCustomObject]@{VM=$VM.Name
            Queued=(Get-Date)}
		}
    }
}