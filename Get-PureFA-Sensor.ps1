<#
________________________________________________
                                                |
      _______                                   |
     /        \                                 |
    /   ____   \                                |
   /   /    \   \                               |
   \   \    /___/  Pure Storage                 |
    \   \                                       |
     \___\                                      |
                                                |
                                                |
    Pure FlashArray Family PRTG Sensor          |
                                                |
________________________________________________|

    Requirements:  Purity 4.7 minimum (REST API 1.6)

==========================================================

This sensor allows the monitoring of FlashArray components as required. 
Supported components include:

- Array Capacity and consumption details
- Array Performance details
- Hardware components health status
- Drive health status
- Volume performance details
- Host group performance details

Each of these options is its own sensor. This is required due to the supported 
sensor maximum of 50 channels per sensor (not enforced)

---------------------------
Version History

Version 1.10 - Added support for volume level monitoring
Version 1.01 - Updated to fix issue with channnel status classifictaions for drive and hardware sensors
Version 1.00 - Initial release, this will keep evolving  

#>

<#
.SYNOPSIS
Outputs a PRTG XML structure with a Pure Storage Array capacity data

.DESCRIPTION
Provides a look at the global array capaicty metrics and at the inidividual
volumes consumption levels. If account credentials are provided it will obtain an 
API Key from the array, if an API key is provided it skips this step. It is encouraged
to provide an API key for the array so that account credentials dont need to be provided

Written for Purity REST API 1.6

.INSTRUCTIONS
1) Copy the script file into the PRTG Custom EXEXML sensor directory C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML
        - Get-PureFA-Sensor.ps1 (PowerShell Sensor Script)
2) Copy the Lookup files into the PRTG lookup file directory C:\Program Files (x86)\PRTG Network Monitor\lookups\custom
        - prtg.standardlookups.purestorage.drivestatus.ovl (Drive status value lookup file)
        - prtg.standardlookups.purestorage.hardwarestatus.ovl (Hardware status value lookup file)
3) Restart the 'PRTG Core Server Service' windows service to load the custom lookup files
3) Create Sensor Custom EXE/ Script Advanced Sensor for each sensor you wish to monitor (refer Scope) and give it a meaniful name
4) Set Parameters for sensor
    - (ArrayAddress) Target Array management DNS name or IP address
    - (UserName) and (Password) or (APIKey) to gain access 
    - (Scope) to set which element to monitor with Sensor
   e.g. -arrayaddress '%host' -scope 'hardware' -apikey '3bdf3b60-f0c0-fa8a-83c1-b794ba8f562c'
5) For the monitoring of individual volumes a sensor is created for each volume. As such the scope option 'volumemanage' is required to maintain these
   sensors. THis then copies itself to a new sensor assigned to the holding device and updates the paramdeters accordingly. It also removes sensors of any 
   volume that has been deleted 
    - Create 'VolumeManage' sensor with the additional parameters -prtghosturl -prtguser -prtgpassword -DeviceID -SensorID


.NOTES
Author: lloydy@purestorage.com
Version: 1.10
Date: 6/9/2017

.PARAMETER ArraryAddress
DNS Name or IP Address of the FlashArray

.PARAMETER UserName
The name of the account to be used to access the array (not required if API token provided)

.PARAMETER Password
The password of the account 

.PARAMETER APIKey
An API Key generated from within the Purity console linked to the account to be used (not required if UserName and Password supplied)

.PARAMETER Scope
The scope defines the details to be monitored from the array
Supported Scope Values:

-   Capacity
-   Performance      
-   Hardware
-   Drive
-   VolumeManage (creates a sensor for each volume)
-   Volume (Sensor created dynamically)
-   HostGroup (not currently supported)

.PARAMETER Item
For monitoring of volumes and hostgroups lets the sensor have the targetted item specified

.PARAMETER SensorID
For new sensor creation for volumes and host groups a copy of the calling sensor is created. This needs to be done with the SensorID so use 
the parameter with the %sensorid which passes the sensorid through. This is required as the API does not currently support the creation of new sensors :(

.PARAMETER DeviceID
For new sensor creation this is the DeviceID of the parent device. Use the %deviceid parameter in the arguments

.PARAMETER PRTGHostURL
The URL to be used to make API calls back to the PRTG host to manage sensors eg http://prtg.domain.local, https://prtg.domain.local, https://prtg.domain.local:8443

.PARAMETER PRTGUser
Account to access PRTG API Service

.PARAMETER PRTGPassword
Password for account used to access PRTG API Service

.PARAMETER DebugDump
Will provide console prompts duering execution. Can not be enabled when running a a sensor

.EXAMPLES
Array Capacity Monitor
C:\PS>Get_PureFA-Sensor.ps1 -ArrayAddress 1.2.3.4 -Username pureuser -Password purepassword -Scope Array
Volume Sensor Manager
C:\PS>Get_PureFA-Sensor.ps1 -ArrayAddress 1.2.3.4 -Username pureuser -Password purepassword -Scope VolumeManage -deviceid 1234 -sensorid 4321 -PRTGHostURL https://prtg.domain.local -PRTGUser admin -PRTGPassword password


#>

param(
    #[Parameter(Mandatory=$true)]
    [string]$ArrayAddress = $null,
    [string]$UserName = $null,
    [string]$Password = $null,
    [string]$APIKey = $null,
    [string]$Scope = $null,
    [string]$Item = $null,
    [string]$SensorID = $null,
    [string]$DeviceID = $null,
    [string]$PRTGHostURL = $null,
    [string]$PRTGUser = $null,
    [string]$PRTGPassword = $null,
    [switch]$DebugDump = $false
)

# Global Variables
$global:arrayname = $null
$apiversion = "1.6"
[string]$array = "https://$($ArrayAddress)"
$global:output = "<?xml version='1.0' encoding='UTF-8' ?><prtg>"
$scriptName = $MyInvocation.MyCommand.Name
$scriptPath = Split-Path $MyInvocation.MyCommand.Path
$global:sensorlistfile = $null

# Lookup files are used to translate between the integer values applied to each channel value in 
# replacement for default textual values. PRTG requires numeric values
$driveLookupFile = "prtg.standardlookups.purestorage.drivestatus"
$hardwareLookupFile = "prtg.standardlookups.purestorage.hardwarestatus"

# Hashtables for the translation from the arrays textual status values to a 
$hardware_status = @{
    ok= 0
    not_installed = 1
    noncritical = 2
    degraded = 3
    unknown = 4
    identifying = 5
    fake_scanner = 6
    vm_scanner = 7
    device_off = 8
    hwman_internal_error = 9
    critical = 10
    }

$drive_status = @{
    healthy = 0
    empty = 1
    updating = 2
    unused = 3
    evacuating = 4
    identifying = 5
    unhealthy = 6
    recovering = 7
    unrecognized = 8
    failed = 9
    }


# Function so show a console message if debug is enabled
function Show-Message($type,$message){
    if($DebugDump){
        Write-Host ("$(Get-Date) ") -NoNewline;
        switch ($type.tolower()){
            "info"          { Write-Host "information "  -BackgroundColor Blue   -ForegroundColor White -NoNewline; }
            "warning"       { Write-Host "warning     "  -BackgroundColor Yellow -ForegroundColor White -NoNewline; }
            "error"         { Write-Host "error       "  -BackgroundColor Red    -ForegroundColor White -NoNewline; }
            default         { Write-Host "misc        "  -BackgroundColor Black  -ForegroundColor White -NoNewline; }
        }
        Write-Host (" $($message)")
    }
}



# Error Reporting Function
function ErrorState{
    param(
        [string]$level,
        [string]$operation,
        [string]$message
    )

    Show-Message "error" "$($operation): $($message)"
    Write-Output '<?xml version="1.0" encoding="UTF-8" ?>'
    write-output "<prtg>"
    Write-Output "<error>$($level)</error>"
    Write-Output "<text>$($operation): $($message)</text>"
    Write-Output "</prtg>"
    exit
}


# Get the API token for the account if not provided
function Get-APIToken{
    param(
        [string]$username,
        [string]$password
    )

    Show-Message "info" "Obtaining API Token as not provided"

    $cred = (convertto-json @{
            username=$username
            password=$password})
    try{
        $apiret = Invoke-RestMethod -Uri "$array/api/$apiversion/auth/apitoken" -Method Post -Body $cred -ContentType "application/json"
    }
    catch{
        ErrorState "1"  "API Token Retrieve Failed"  $_.Exception.Message
    }

    return $apiret.api_token
}
    
# Log into the array
function Get-Session{

    Show-Message "info" "Logging into the array"
    Set-Variable -Name APIKey -Value $APIKey -Scope 
    if(!$APIKey){$Script:APIKey = Get-APIToken $UserName $Password}
    $apitoken = (ConvertTo-Json @{api_token=$APIKey})

    try{
        $apiret = Invoke-RestMethod -Uri "$array/api/$apiversion/auth/session" -Method Post -Body $apitoken -ContentType "application/json" -SessionVariable websession
        $UserName = $apiret.username
    }
    catch{
        ErrorState "1"  "Login Failed"  $_.Exception.Message
    }
    return $websession
}

# Create Result Element
function Get-ResultElement{
    param(
        [string]$channel,
        [string]$value,
        [string]$unit = "Count",
        [string]$customunit = $null,
        [string]$float = 1,
        [string]$volumesize = "One",
        [bool]$notifychanged = $false,
        [string]$valuelookup = $null,
        [bigint]$warningmin = -1,
        [bigint]$warningmax = -1,
        [string]$warningmsg = $null,
        [bigint]$errormin = -1,
        [bigint]$errormax = -1,
        [string]$errormsg = $null,
        [int]$decimalmode = 0,
        [bool]$sensorwarning = $false,
        [bool]$limitmode = $false, 
        [bool]$showchart = $true,
        [bool]$showtable = $true

    )

    $result = "<Result>"
    $result += [string]::Format("<Channel>{0}</Channel>",$channel)
    $result += [string]::Format("<Value>{0}</Value>", $value)
    $result += [string]::Format("<unit>{0}</unit>", $unit)
    if ($unit -eq "custom"){
        $result += [string]::Format("<CustomUnit>{0}</CustomUnit>", $customunit)
    }
    $result += [string]::Format("<Float>{0}</Float>", $float)
    $result += [string]::Format("<volumeSize>{0}</volumeSize>", $volumesize)
    $result += [string]::Format("<DecimalMode>{0}</DecimalMode>", $decimalmode)
    if($notifychanged){
        $result += "<NotifyChanged></NotifyChanged>"
    }
    if($valuelookup){
        $result += [string]::Format("<ValueLookup>{0}</ValueLookup>", $valuelookup)
    }
    if($warningmin -ge 0){
        $limitmode = $true
        $result += [string]::Format("<LimitMinWarning>{0}</LimitMinWarning>", $warningmin)}
    elseif($warningmax -ge 0){
        $limitmode = $true
        $result += [string]::Format("<LimitMaxWarning>{0}</LimitMaxWarning>", $warningmax)
    }
    if($warningmsg){
        $result += [string]::Format("<LimitWarningMessage>{0}</LimitWarningMessage>", $warningmsg)
    }
    if($errormin -ge 0){
        $limitmode = $true
        $result += [string]::Format("<LimitMinError>{0}</LimitMinError>", $errormin)}
    elseif($errormax -ge 0){
        $limitmode = $true
        $result += [string]::Format("<LimitMaxError>{0}</LimitMaxError>", $errormax)
    }
    if($errormsg){
        $result += [string]::Format("<LimitErrorMessage>{0}</LimitErrorMessage>", $errormsg)
    }
    if($limitmode){$result += "<LimitMode>1</LimitMode>"}
    if($sensorwarning){$result += "<Warning>1</Warning>"}
    if(!$showchart){$result += "<ShowChart>0</ShowChart>"}
    if(!$showtable){$result += "<ShowTable>0</ShowTable>"}


    $result += "</Result>"

    return $result
}

# Check if sensor already exists
function Check-SensorExists{
    param(
        [string]$sensorname
        )

    $sensorlist = (Get-Content $global:sensorlistfile)
        
    if(!($sensorlist -contains $sensorname)){
        return $false
    }
    else {
        return $true
    }
}

# Get gneral array details
function Get-ArrayDetails{
    Show-Message "info" "Get Array Identification Details"

    try{
        $array = Invoke-RestMethod -Uri "$array/api/$apiversion/array" -websession $mysession -ContentType "application/json"
        $global:arrayname = $array[0].array_name
        $global:sensorlistfile = [string]::Format("{0}\{1}-sensors.list", $scriptPath, $global:arrayname)
        if(!(Test-Path $global:sensorlistfile)){
            New-Item -ItemType File -Path $global:sensorlistfile | Out-Null
            Show-Message "info" "Created sensor list file: $($global:sensorlistfile)"
        }

    }
    catch{
        ErrorState "1"  "Array Details Query Failed"  $_.Exception.Message
    }
}

# Get Array Level Space Details
function Get-ArraySpace{

    Show-Message "info" "Get Array Space Usage Details"

    try{
        $arrayspace = Invoke-RestMethod -Uri "$array/api/$apiversion/array?space=true" -websession $mysession -ContentType "application/json"

        $sensorname = [string]::Format("{0}-Capacity", $arrayname)
        $sensoroutput = $global:output      
        $available = ($arrayspace[0].capacity - $arrayspace[0].total)
        $percentfree = [math]::Round((($available / $arrayspace[0].capacity) * 100))
        $warningavailable = ($arrayspace[0].capacity * .2)
        $erroravailable = ($arrayspace[0].capacity * .1)
        $warningmax = ($arrayspace[0].capacity * .8)
        $errormax = ($arrayspace[0].capacity * .9)
        $warningmsg = "Consumed space high, clear space before error occurs"
        $errormsg = "Array space dangerously low, clear space immediaitely"
        $unallocwarnmsg = "Watch unallocated for consistent reading >0, system not working efficiently"
        $unallocerrormsg = "Excessive unallocated, system not working efficiently"

        $sensoroutput += Get-ResultElement `
                                -channel "Free Space %" `
                                -value  $percentfree `
                                -unit "Percent" `
                                -warningmin 20 `
                                -errormin 10  `
                                -warningmsg $warningmsg `
                                -errormsg $errormsg `
                                -float 1 `
                                -decimalmode 1
        $sensoroutput += Get-ResultElement `
                                -channel "Consumed Space %" `
                                -value  (100 - $percentfree) `
                                -unit "Percent" `
                                -warningmax 80 `
                                -errormax 90  `
                                -warningmsg $warningmsg `
                                -errormsg $errormsg `
                                -float 1 `
                                -decimalmode 1
        $sensoroutput += Get-ResultElement `
                                -channel "Total Capacity" `
                                -value $arrayspace[0].capacity `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -float 0 `
                                -showchart $false
        $sensoroutput += Get-ResultElement `
                                -channel "Capacity Available" `
                                -value $available `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -float 0 `
                                -warningmin $warningavailable `
                                -errormin $erroravailable `
                                -warningmsg $warningmsg `
                                -errormsg $errormsg
        $sensoroutput += Get-ResultElement `
                                -channel "Capacity Used" `
                                -value $arrayspace[0].total `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -float 0 `
                                -warningmax $warningmax `
                                -errormax $errormax `
                                -warningmsg $warningmsg `
                                -errormsg $errormsg 
        $sensoroutput += Get-ResultElement `
                                -channel "Unallocated Space" `
                                -value $arrayspace[0].system `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -warningmax $erroravailable `
                                -warningmsg $unallocwarnmsg `
                                -errormax ($erroravailable * 2) `
                                -errormsg $unallocerrormsg
        $sensoroutput += Get-ResultElement `
                                -channel "Data Reduction Rate" `
                                -value $arrayspace[0].data_reduction `
                                -float 0 `
                                -decimalmode 1 `
                                -showchart $false `
                                -showtable $false
        #$sensoroutput += "<text>Array Capacity Details</text>"
        $sensoroutput += "</prtg>"

        Write-Output $sensoroutput
    }
    catch{
        ErrorState "1"  "Array Space Query Failed"  $_.Exception.Message
    }
}

# Get current array level performance details
function Get-ArrayPerformance{

    Show-Message "Info" "Get Array Performance Details"

    try{
        $arrayperf = Invoke-RestMethod -Uri "$array/api/$apiversion/array?action=monitor" -websession $mysession -ContentType "application/json"
        
        $sensorname = [string]::Format("{0}-Performance", $arrayname)
        $sensoroutput = $global:output      
        $sensoroutput += Get-ResultElement `
                                -channel "Latency Read" `
                                -value $arrayperf[0].usec_per_read_op `
                                -unit "custom" `
                                -customunit "usec"
        $sensoroutput += Get-ResultElement `
                                -channel "Latency Write" `
                                -value $arrayperf[0].usec_per_write_op `
                                -unit "custom" `
                                -customunit "usec"
        $sensoroutput += Get-ResultElement `
                                -channel "Read Operations" `
                                -value $arrayperf[0].reads_per_sec `
                                -unit "custom" `
                                -customunit "IOPS"
        $sensoroutput += Get-ResultElement `
                                -channel "Write Operations" `
                                -value $arrayperf[0].writes_per_sec `
                                -unit "custom" `
                                -customunit "IOPS"
        $sensoroutput += Get-ResultElement `
                                -channel "Bandwidth Read" `
                                -value $arrayperf[0].output_per_sec `
                                -float 0 `
                                -decimalmode 0 `
                                -unit "BytesBandwidth" `
                                -volumesize "MegaBit"
        $sensoroutput += Get-ResultElement `
                                -channel "Bandwidth Write" `
                                -value $arrayperf[0].input_per_sec `
                                -float 0 `
                                -decimalmode 0 `
                                -unit "BytesBandwidth" `
                                -volumesize "MegaBit"
        $sensoroutput += Get-ResultElement `
                                -channel "Queue Depth" `
                                -value $arrayperf[0].queue_depth `
                                -warningmax 60 `
                                -errormax 100 `
                                -float 0
        #$sensoroutput += "<text>Array Performance Details</text>"
        $sensoroutput += "</prtg>"

        Write-Output $sensoroutput
    }
    catch{
        ErrorState "1"  "Array Perf Query Failed"  $_.Exception.Message
    }
}

# Get Array hardware Status
function Get-HardwareStatus{
    Show-Message "Info" "Get Array Hardware Status"


    try{
        $hardware = Invoke-RestMethod -Uri "$array/api/$apiversion/hardware" -websession $mysession -ContentType "application/json"

        $sensorname = [string]::Format("{0}-Hardware", $arrayname)
        $sensoroutput = $null  
        $overallcondition = 0   
        foreach($item in $hardware){
            $hardwareid = ""
            if($item.name.length -eq 3){
                switch($item.name.substring(0,2)){
                    "CH" {$hardwareid = [string]::Format("Chassis {0}", $item.name.substring(2,1))}
                    "CT" {$hardwareid = [string]::Format("Controller {0}", $item.name.substring(2,1))}
                    "SH" {$hardwareid = [string]::Format("Shelf {0}", $item.name.substring(2,1))}
                    default {$hardwareid = $item.name}
                }
                $sensoroutput += Get-ResultElement `
                                        -channel $hardwareid `
                                        -value $hardware_status[$item.status] `
                                        -unit "custom" `
                                        -customunit "Status" `
                                        -valuelookup $hardwareLookupFile
                
                if($hardware_status[$item.status] -eq 10){
                    $overallcondition = 10}
                elseif(($hardware_status[$item.status] -ge 2) -and ($overallcondition -ne 10)){
                    $overallcondition = 3}

            }

        }
        $sensoroutput = $global:output + `
                        (Get-ResultElement `
                                    -channel "Hardware Overall" `
                                    -value $overallcondition `
                                    -unit "custom" `
                                    -customunit "Status" `
                                    -valuelookup $hardwareLookupFile) + $sensoroutput
        #$global:output += "<text>Hardware Health</text>"
        $sensoroutput += "</prtg>"
        Write-Output $sensoroutput
    }
    catch{
        ErrorState "1"  "Hardware Query Failed"  $_.Exception.Message
    }
}

# Get Drive health status
function Get-DriveStatus(){
    Show-Message "Info" "Get Drive Status"

    try{
        $drives = Invoke-RestMethod -Uri "$array/api/$apiversion/drive" -websession $mysession -ContentType "application/json"

        $sensorname = [string]::Format("{0}-Drive", $arrayname)
        $overallcondition = 0   
        foreach($drive in $drives){ 
            $sensoroutput += Get-ResultElement `
                                    -channel $drive.name `
                                    -value $drive_status[$drive.status] `
                                    -unit "custom" `
                                    -customunit "Status" `
                                    -valuelookup $driveLookupFile `
                                    -showchart $false
            
            if($drive_status[$drive.status] -gt 3){$overallcondition = 6}
        }
        $sensoroutput = $global:output + `
                        (Get-ResultElement `
                                -channel "Drives Overall" `
                                -value $overallcondition `
                                -unit "custom" `
                                -customunit "Status" `
                                -valuelookup $driveLookupFile) + $sensoroutput

        $sensoroutput += "</prtg>"

        Write-Host $sensoroutput
    }
    catch{
        ErrorState "1"  "Drive Query Failed"  $_.Exception.Message
    }
}

# Function to create sensors for each volume
function Create-VolumeSensors{
    Show-Message "info" "Create Volume Sensors"

    $action = "Enumerate Volumes"
    try{
        $currentvolumes = Get-Content -raw $global:sensorlistfile | ConvertFrom-StringData
        if ($currentvolumes.Count -eq 0){
            $currentvolumes = @{"dummy"=1}
        }
        $volumes = Invoke-RestMethod -Uri "$array/api/$apiversion/volume" -websession $mysession -ContentType "application/json"
        
        foreach($volume in $volumes){
            if(!($currentvolumes[$volume.name])){
                Show-Message "info" "Create Volume: $($volume.name)"

                $action = "Create sensor"
                # Create Sensor
                $url = [string]::Format("{0}/api/duplicateobject.htm?id={1}&name={2}&targetid={3}&username={4}&password={5}",
                                            $PRTGHostURL, $SensorID, "vol-$($volume.name)", $DeviceID, $PRTGUser, $PRTGPassword);

                $request = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -ErrorAction Ignore -UseBasicParsing
                
                if($request.StatusCode -ge 300 -and $request.StatusCode -lt 400) {
                    $action = "Update sensor"
                    $newSensorID = $request.Headers.Location.Split('=')[1]

                    # Append new sensor name and ID to list file
                    $action = "Add file entry"
                    Write-Output "$($volume.name) = $($newSensorID)" | Add-Content $global:sensorlistfile

                    Show-Message "info" "Sensor created successfully. New sensor ID: $($newSensorID)";

                    # Modify Sensor to set params to monitor volume
                    $exeparams = [string]::Format("-arrayaddress '{0}' -apikey '{1}' -scope volume -item '{2}'", 
                                            $ArrayAddress, $APIKey, $volume.name)

                    $url = [string]::Format("{0}/api/setobjectproperty.htm?id={1}&name={2}&value={3}&username={4}&password={5}",
                                            $PRTGHostURL, $newSensorID, "exeparams", $exeparams, $PRTGUser, $PRTGPassword);

                    $request = Invoke-WebRequest -Uri $url -UseBasicParsing

                    if($request.StatusCode -eq 200){
                        # Unpause Sensor
                        $action = "Unpause sensor"
                        $url = [string]::Format("{0}/api/pause.htm?id={1}&action=1&username={2}&password={3}",
                                                    $PRTGHostURL, $newSensorID, $PRTGUser, $PRTGPassword);
                        $request = Invoke-WebRequest -Uri $url -UseBasicParsing
                        if($request.StatusCode -eq 200){
                            Show-Message "info" "Sensor ID: $($newSensorID) updated and started successfully";

                        }
                    }

                }
                else{
                    ErrorState "1" "Volume Sensor creation Failed. PRTG returned code $($request.StatusCode)"
                }

            }
            else{
                $currentvolumes.Remove($volume.name)
            }
        }
        
        # Cleanup sensors of Volumes deleted from array
        if($currentvolumes.Count -gt 0){
            $action = "Sensor cleanup"
            $sensorlist = (Get-Content $global:sensorlistfile)
            foreach ($item in $currentvolumes){
                if(Delete-Sensor -sensorid $item.Value){
                    $sensorlist.Replace("$($item.Name) = $($item.Value)`n", "") 
                }
            }
            Write-Host $sensorlist | Out-File $global:sensorlistfile | Out-Null
        }
        Write-Host "<prtg><result><channel>Scan Status</channel><value>1</value></result></prtg>"
    }
    catch{
        ErrorState "1" "Volume Sensor creation Failed at $($action) with " $_.Exception.Message
    }
}

# Delete specified sensor
function Delete-Sensor{
    param(
        [string]$sensorid
        )

        $url = [string]::Format("{0}/api/deleteobject.htm?id={1}&approve=1&username={2}&password={3}", $PRTGHostURL, $sensorid, $PRTGUser, $PRTGPassword)
        $request = Invoke-WebRequest -Uri $url

        if($request.StatusCode -eq 200){
            return $true}
        else{
            return $false
        }
}

# get Volume Level Details
function Get-VolumeStatus{

    Show-Message "info" "Get Volume Details"

    if($Item){
        try{
            Show-Message "info" "Volume: $($Item)"
            $volume = Invoke-RestMethod -Uri "$array/api/$apiversion/volume/$($Item)?space=true" -websession $mysession -ContentType "application/json"
            $available = ($volume.size - $volume.total)
            $percentfree = [math]::Round((($available / $volume.size) * 100))
            $global:output += Get-ResultElement `
                                -channel "Free Space %" `
                                -value  $percentfree `
                                -unit "Percent" `
                                -warningmin 20 `
                                -errormin 10  `
                                -warningmsg "Volume Capacity +80% Full" `
                                -errormsg "Volume Capacity +90% Full" `
                                -float 1 `
                                -decimalmode 1
            $global:output += Get-ResultElement `
                                -channel "Size" `
                                -value $volume.size `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -float 0 `
                                -showchart $false
            $global:output += Get-ResultElement `
                                -channel "Space Available" `
                                -value $available `
                                -unit "BytesDisk" `
                                -volumesize "MegaByte" `
                                -float 0
            Get-VolumePerf $Item
            $global:output += "</prtg>"

            Write-Host $global:output

        }
        catch{
            ErrorState "1" "Volume Usage Query Failed" $_.Exception.Message
        }
    } 
    else{
        ErrorState "1" "Volume 'Item' name parameter not set"
    }
}

# Get Volume level performance statistics
function Get-VolumePerf($volname){
    Show-Message "info" "Get Volume Performance Stats for $($volname)"

    try{
        $volperf = Invoke-RestMethod -Uri "$array/api/$apiversion/volume/$($volname)?action=monitor" -websession $mysession -ContentType "application/json"
        $global:output += Get-ResultElement `
                                -channel "Latency Read" `
                                -value $volperf.usec_per_read_op `
                                -unit "custom" `
                                -customunit "usec"
        $global:output += Get-ResultElement `
                                -channel "Latency Write" `
                                -value $volperf.usec_per_write_op `
                                -unit "custom" `
                                -customunit "usec"
        $global:output += Get-ResultElement `
                                -channel "Read Operations" `
                                -value $volperf.reads_per_sec `
                                -unit "custom" `
                                -customunit "IOPS"
        $global:output += Get-ResultElement `
                                -channel "Write Operations" `
                                -value $volperf.writes_per_sec `
                                -unit "custom" `
                                -customunit "IOPS"
        $global:output += Get-ResultElement `
                                -channel "Bandwidth Read" `
                                -value $volperf.output_per_sec `
                                -float 0 `
                                -decimalmode 0 `
                                -unit "BytesBandwidth" `
                                -volumesize "MegaBit"
        $global:output += Get-ResultElement `
                                -channel "Bandwidth Write" `
                                -value $volperf.input_per_sec `
                                -float 0 `
                                -decimalmode 0 `
                                -unit "BytesBandwidth" `
                                -volumesize "MegaBit"
    }
    catch{
        ErrorState "1" "Volume Performance Query Failed" $_.Exception.Message
    }
}

# Get Host Gropup Performance Details
function Get-HostGroupPerf(){
}

# Delete current web session
# Log into the array
function Delete-Session{

    Show-Message "info" "Logging off array"

    $userdetail = (convertto-json @{username=$username})

    try{
        $retval = Invoke-RestMethod -Uri "$array/api/$apiversion/auth/session" -Method Delete -Body $userdetail -ContentType "application/json"
    }
    catch{
        ErrorState "1"  "Logoff Failed"  $_.Exception.Message
    }
    $retval
}


$timer = [system.diagnostics.stopwatch]::StartNew()

# Set Certificate validation
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12


$mysession = Get-Session
Get-ArrayDetails

switch($Scope.ToUpper()){
    "CAPACITY"     {Get-ArraySpace}
    "PERFORMANCE"  {Get-ArrayPerformance}
    "HARDWARE"     {Get-HardwareStatus}
    "DRIVE"        {Get-DriveStatus}
    "VOLUMEMANAGE" {Create-VolumeSensors}
    "VOLUME"       {Get-VolumeStatus}
    "HOSTGROUP"    {Get-HostGroupPerf}
    default        {Get-ArrayPerformance}
}

$timer.Stop();

#Delete-Session
$mysession = $null



Show-Message "information" "Elapsed Time: $($timer.Elapsed)"

