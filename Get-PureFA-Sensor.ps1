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
1) Copy the three files into the PRTG Custom EXEXML sensor directory C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML
        - Get-PureFA-Sensor.ps1 (PowerShell Sensor Script)
        - PureFA-Lookup-Drive.xml (Drive status value lookup file)
        - PureFA-Lookup-Hardware.xml (Hardware status value lookup file)
2) Create Sensor...
3) Set Parameters
    - (ArrayAddress) Target Array management DNS name or IP address
    - (UserName) and (Password) or (APIKey) to gain access 



.NOTES
Author: lloydy@purestorage.com
Version: 1.00.00
Date: 6/9/2017

.PARAMETER ArraryAddress
DNS Name or IP Address of the FlashArray

.PARAMETER UserName
The name of the account to be used to access the array (not required if API token provided)

.PARAMETER Password
The password of the account 

.PARAMETER APIKey
An API Key generated from within the Purity console linked to the account to be used (not required if UserName and Password supplied)

.PARAMETER DebugDump
will dump table to console at end if set to $true

.EXAMPLE
C:\PS>Get_PureFA-Sensor.ps1 1.2.3.4 pureuser purepassword
#>

param(
    #[Parameter(Mandatory=$true)]
    [string]$ArrayAddress = "10.219.224.102",
    [string]$UserName = 'pureuser',
    [string]$Password = 'pureuser',
    [string]$APIKey = $null,
    [switch]$ArraySensor = $true,
    [switch]$HardwareSensor = $false,
    [switch]$DriveSensor = $false,
    [switch]$VolumeSensor = $false,
    [switch]$HostgroupSensor = $false,
    [switch]$DebugDump = $true
)

# Global
$apiversion = "1.6"
[string]$array = "https://$($ArrayAddress)"
$timer = [system.diagnostics.stopwatch]::new()
$scriptPath = "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\";
$driveLookupFile = "PureFA-Lookup-Drive.xml"
$hardwareLookupFile = "PureFA-Lookup-Hardware.xml"

$hardware_status = @{
    ok= 0
    critical = 1
    noncritical = 2
    degraded = 3
    not_installed = 4
    unknown = 5
    device_off = 6
    hwman_internal_error = 7
    identifying = 8
    fake_scanner = 9
    vm_scanner = 10
    }

$drive_status = @{
    healthy = 0
    empty = 1
    evacuatiung = 2
    identifying = 3
    unrecognized = 4
    unhealthy = 5
    failed = 6
    updating = 7
    unused = 8
    recovering = 9
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

    if(!$apikey){$apikey = Get-APIToken $UserName $Password}
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
        [string]$unit,
        [string]$customunit,
        [string]$float,
        [string]$volumesize,
        [switch]$notifychanged
    )

    $result = "<Result>"
    $result += "<Channel>$($channel)</Channel>"
    $result += "<Value>$($value)</Value>"
    $result += "<Unit>$($unit)</Unit>"
    if ($unit -eq "custom"){
        $result += "<CustomUnit>$($customunit)</CustomUnit>"
    }
    $result += "<Float>$($float)</Float>"
    $result += "<VolumeSize>$($volumesize)</VolumeSize>"
    if($notifychanged){
        $result += "<NotifyChanged></NotifyChanged>"
    }

    $result += "</Result>"

    return $result
}


# Get Array Level Space Details
function Get-ArraySpace{

    Show-Message "info" "Get Array Space Usage Details"

    try{
        $arrayspace = Invoke-RestMethod -Uri "$array/api/$apiversion/array?space=true" -websession $mysession -ContentType "application/json"
        
        Get-ResultElement "Total Capacity"  $arrayspace[0].capacity "BytesDisk" "none" 1 "GigaByte" $false
        Get-ResultElement "Capacity Used"  $arrayspace[0].total "BytesDisk" "none" 1 "GigaByte" $false
        $available = ($arrayspace[0].capacity - $arrayspace[0].total)
        Get-ResultElement "Capacity Available"  $available "BytesDisk" "none" 1 "GigaByte" $false
        Get-ResultElement "Data Reduction Rate"  $arrayspace[0].data_reduction "Count" "none" 1 "One" $false

        #write-host $arrayspace[0].shared_space
        #write-host $arrayspace[0].snapshots
        #write-host $arrayspace[0].system
        #write-host $arrayspace[0].volumes
        #write-host $arrayspace[0].thin_provisioning
        #write-host $arrayspace[0].total_reduction
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
        Get-ResultElement "IOPs Reads" $arrayperf[0].reads_per_sec "Count" "none" 1 "One" $false
        Get-ResultElement "IOPs Writes" $arrayperf[0].writes_per_sec "Count" "none" 1 "One" $false
        Get-ResultElement "Bandwidth Read" $arrayperf[0].output_per_sec "BytesBandwidth" "none" 1 "MegaBit" $false
        Get-ResultElement "Bandwidth Write" $arrayperf[0].input_per_sec "BytesBandwidth" "none" 1 "MegaBit" $false
        Get-ResultElement "Latency Read μs" $arrayperf[0].usec_per_read_op "TimeResponse" "none" 1 "One" $false
        Get-ResultElement "Latency Write μs" $arrayperf[0].usec_per_write_op "TimeResponse" "none" 1 "One" $false

        #write-host $arrayperf[0].
        #write-host $arrayperf[0].x
        #write-host $arrayperf[0].queue_depth
        #write-host $arrayperf[0].
        #write-host $arrayperf[0].
    }
    catch{
        ErrorState "1"  "Array Perf Query Failed"  $_.Exception.Message
    }
}

# Get Array hardware Status
function get-HardwareStatus{
    Show-Message "Info" "Get Array Hardware Status"

    try{
        $hardware = Invoke-RestMethod -Uri "$array/api/$apiversion/hardware" -websession $mysession -ContentType "application/json"
        foreach($item in $hardware){
            if($item.name.substring(0,2) -eq "CT"){
                #write-host "Hardware: $($item.name)     Status: $($item.Status)"
            } 
        }
    }
    catch{
        ErrorState "1"  "Hardware Query Failed"  $_.Exception.Message
    }
}

# Get Drive health status
function get-DriveStatus(){
    Show-Message "Info" "Get Drive Status"

    try{
        $drives = Invoke-RestMethod -Uri "$array/api/$apiversion/drive" -websession $mysession -ContentType "application/json"
        foreach($drive in $drives){
            #write-host "Drive: $($drive.name)     Status: $($drive.Status)" 
        }
    }
    catch{
        ErrorState "1"  "Drive Query Failed"  $_.Exception.Message
    }
}

# get Volume Level Details
function Get-VolumeUsage{

    Show-Message "info" "Get Volume Details"

    try{
        $volumes = Invoke-RestMethod -Uri "$array/api/$apiversion/volume?space=true" -websession $mysession -ContentType "application/json"
        foreach($volume in $volumes){
            #Show-Message "info" "Volume: $($volume.name)"
            #write-host $volume.name
            Get-VolumePerf $volume.name
            #write-host $volume.data_reduction
            #write-host $volume.size
            #write-host $volume.total
            #write-host $volume.total_reduction
        }

    }
    catch{
        ErrorState "1" "Volume Usage Query Failed" $_.Exception.Message
    }
}

function Get-VolumePerf($volname){
    Show-Message "info" "Get Volume Performance Stats for $($volname)"

    try{
        $volperf = Invoke-RestMethod -Uri "$array/api/$apiversion/volume/$($volname)?action=monitor" -websession $mysession -ContentType "application/json"
        #write-host $volperf.input_per_sec
        #write-host $volperf.output_per_sec
        #write-host $volperf.reads_per_sec
        #write-host $volperf_writes_per_sec
        #write-host $volperf.usec_per_read_op
        #write-host $volperf.usec_per_write_op
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



$timer.Start();


# Set Certificate validation
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12


$mysession = Get-Session

if($ArraySensor){
    Get-ArraySpace
    Get-ArrayPerformance
}
if($HardwareSensor){
    Get-HardwareStatus}
if($DriveSensor){
    get-DriveStatus}
if($VolumeSensor){
    Get-VolumeUsage}
if($HostgroupSensor){
    Get-HostGroupPerf}

#Delete-Session
$mysession = $null

$timer.Stop();

Show-Message "information" "Elapsed Time: $($timer.Elapsed)"

