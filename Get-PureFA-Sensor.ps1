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
Version: 1.00
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
-   Volume
-   HostGroup

.PARAMETER DebugDump
Will provice console promots duering execution. Can not be enabled when running a a sensor

.EXAMPLE
C:\PS>Get_PureFA-Sensor.ps1 -ArrayAddress 1.2.3.4 -Username pureuser -Password purepassword -Scope Array

#>

param(
    #[Parameter(Mandatory=$true)]
    [string]$ArrayAddress = "172.16.85.10",
    [string]$UserName = $null,
    [string]$Password = $null,
    [string]$APIKey = "87c64157-6d0d-6284-bded-29ca6a9d44bb",
    [string]$Scope = "capacity",
    [switch]$DebugDump = $true
)

# Global Variables
$apiversion = "1.6"
[string]$array = "https://$($ArrayAddress)"
$timer = [system.diagnostics.stopwatch]::new()
$scriptPath = "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\";

# Lookup files are used to translate between the integer values applied to each channel value in 
# replacement for default textual values. PRTG requires numeric values
$driveLookupFile = "PureFA-Lookup-Drive.xml"
$hardwareLookupFile = "PureFA-Lookup-Hardware.xml"

# Hashtables for the translation from the arrays textual status values to a 
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
        [string]$unit = "Count",
        [string]$customunit = $null,
        [string]$float = 1,
        [string]$volumesize = "One",
        [bool]$notifychanged = $false,
        [string]$valuelookup = $null,
        [int]$warningmin = -1,
        [int]$warningmax,
        [string]$warningmsg = $null,
        [int]$errormin = -1,
        [int]$errormax,
        [string]$errormsg = $null

    )

    $result = "<Result>"
    $result += [string]::Format("<Channel>{0}</Channel>",$channel)
    $result += [string]::Format("<Value>{0}</Value>", $value)
    $result += [string]::Format("<Unit>{0}</Unit>", $unit)
    if ($unit -eq "custom"){
        $result += [string]::Format("<CustomUnit>{0}</CustomUnit>", $customunit)
    }
    $result += [string]::Format("<Float>{0}</Float>", $float)
    $result += [string]::Format("<VolumeSize>{0}</VolumeSize>", $volumesize)
    if($notifychanged){
        $result += "<NotifyChanged></NotifyChanged>"
    }
    if($valuelookup){
        $result += [string]::Format("<ValueLookup>{0}</ValueLookup>", $valuelookup)
    }
    if($warningmin -ge 0){
        $result += [string]::Format("<LimitMinWarning>{0}</LimitMinWarning>", $warningmin)
        $result += [string]::Format("<LimitMaxWarning>{0}</LimitMaxWarning>", $warningmax)
        if($warningmsg){
            $result += [string]::Format("<LimitWarningMessage>{0}</LimitWarningMessage>", $warningmsg)
        }
    }
    if($errormin -ge 0){
        $result += [string]::Format("<LimitMinError>{0}</LimitMinError>", $errormin)
        $result += [string]::Format("<LimitMaxError>{0}</LimitMaxError>", $errormax)
        if($errormsg){
            $result += [string]::Format("<LimitErrorMessage>{0}</LimitErrorMessage>", $errormsg)
        }
    }

    $result += "</Result>"

    return $result
}


# Get Array Level Space Details
function Get-ArraySpace{

    Show-Message "info" "Get Array Space Usage Details"

    try{
        $arrayspace = Invoke-RestMethod -Uri "$array/api/$apiversion/array?space=true" -websession $mysession -ContentType "application/json"
        
        $available = ($arrayspace[0].capacity - $arrayspace[0].total)
        $percentavailable = 1 / ($available / $arrayspace[0].capacity)
        $warningmin = ($arrayspace[0].capacity * .8)
        $warningmax = (($arrayspace[0].capacity * .9) -1)
        $errormin = ($arrayspace[0].capacity * .9)
        $errormax = ($arrayspace[0].capacity - 1)
        $warningmsg = "Consumed space high, clear space before error occurs"
        $errormsg = "Array space dangerous, clear space immediaitely"

        $global:output += Get-ResultElement 
                                -channel "Total Capacity" 
                                -value $arrayspace[0].capacity 
                                -unit "BytesDisk" 
                                -volumesize "GigaByte"
        $global:output += Get-ResultElement 
                                -channel "Capacity Used" 
                                -value $arrayspace[0].total 
                                -unit "BytesDisk" 
                                -volumesize "GigaByte" 
                                -warningmin $warningmin 
                                -warningmax $warningmax 
                                -errormin $errormin 
                                -errormax $errormax 
                                -warningmsg $warningmsg 
                                -errormsg $errormsg
        $global:output += Get-ResultElement 
                                -channel "Capacity Available" 
                                -value $available 
                                -unit "BytesDisk" 
                                -volumesize "GigaByte"
        $global:output += Get-ResultElement 
                                -channel "Percent Free" 
                                -value  $percentavailable 
                                -unit "Percent" 
                                -warningmin .8 
                                -warningmax .899 
                                -errormin .9 
                                -errormax 3  
                                -warningmsg $warningmsg 
                                -errormsg $errormsg
        $global:output += Get-ResultElement 
                                -channel "Data Reduction Rate" 
                                -value $arrayspace[0].data_reduction


        #write-host $arrayspace[0].shared_space
        #write-host $arrayspace[0].snapshots
        #write-host $arrayspace[0].system
        #write-host $arrayspace[0].volumes
        #write-host $arrayspace[0].thin_provisioning
        #write-host $arrayspace[0].total_reduction
        $global:output += "<text>Array Capacity Details</text>"
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
        
        $global:output += Get-ResultElement 
                                -channel "IOPs Reads" 
                                -value $arrayperf[0].reads_per_sec
        $global:output += Get-ResultElement 
                                -channel "IOPs Writes" 
                                -value $arrayperf[0].writes_per_sec
        $global:output += Get-ResultElement 
                                -channel "Bandwidth Read" 
                                -value $arrayperf[0].output_per_sec
                                -unit "BytesBandwidth" 
                                -volumesize "MegaBit"
        $global:output += Get-ResultElement 
                                -channel "Bandwidth Write" 
                                -value $arrayperf[0].input_per_sec 
                                -unit "BytesBandwidth" 
                                -volumesize "MegaBit"
        $global:output += Get-ResultElement 
                                -channel "Latency Read μs" 
                                -value $arrayperf[0].usec_per_read_op 
                                -unit "TimeResponse"
        $global:output += Get-ResultElement 
                                -channel "Latency Write μs" 
                                -value $arrayperf[0].usec_per_write_op 
                                -unit "TimeResponse"
        $global:output += Get-ResultElement 
                                -channel "Queue Depth" 
                                -value $arrayperf[0].queue_depth 
                                -float 0
        $global:output += "<text>Array Performance Details</text>"
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

        foreach($item in $hardware){
            if($item.name.substring(0,2) -eq "CT"){
                $global:output += Get-ResultElement "Component $($item.name)" $hardware_status[$item.status] "Count" "none" 0 "One" $true ($scriptPath + $hardwareLookupFile)
            } 
        }
        $global:output += "<text>Hardware Health</text>"
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

        foreach($drive in $drives){ 
            $global:output += Get-ResultElement "Drive $($drive.name)" $drive_status[$drive.status] "Count" "none" 0 "One" $true ($scriptPath + $driveLookupFile)
        }
        $global:output += "<text>Drive Health</text>"
    }
    catch{
        ErrorState "1"  "Drive Query Failed"  $_.Exception.Message
    }
}

# get Volume Level Details
function Get-VolumeStatus{

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
$global:output = '<?xml version="1.0" encoding="UTF-8" ?><prtg>'


switch($Scope.ToUpper()){
    "CAPACITY"     {Get-ArraySpace}
    "PERFORMANCE"  {Get-ArrayPerformance}
    "HARDWARE"     {Get-HardwareStatus}
    "DRIVE"        {Get-DriveStatus}
    "VOLUME"       {Get-VolumeStatus}
    "HOSTGROUP"    {Get-HostGroupPerf}
    default        {Get-ArrayPerformance}
}

$global:output += '</prtg>'

#Delete-Session
$mysession = $null

$timer.Stop();

Write-Host $global:output

Show-Message "information" "Elapsed Time: $($timer.Elapsed)"

