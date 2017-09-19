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
-   Volume (not currently supported)
-   HostGroup (not currently supported)

.PARAMETER DebugDump
Will provice console promots duering execution. Can not be enabled when running a a sensor

.EXAMPLE
C:\PS>Get_PureFA-Sensor.ps1 -ArrayAddress 1.2.3.4 -Username pureuser -Password purepassword -Scope Array

#>

param(
    #[Parameter(Mandatory=$true)]
    [string]$ArrayAddress = "10.219.224.112",
    [string]$UserName = $null,
    [string]$Password = $null,
    [string]$APIKey = "3bdf3b60-f0c0-fa8a-83c1-b794ba8f562c",
    [string]$Scope = "drive",
    [switch]$DebugDump = $false
)

# Global Variables
$global:arrayname = $null
$apiversion = "1.6"
[string]$array = "https://$($ArrayAddress)"
$sensorlistfile = $null
$scriptPath = "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\";
$global:output = '<prtg>'

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
        [bigint]$warningmin = -1,
        [bigint]$warningmax = -1,
        [string]$warningmsg = $null,
        [bigint]$errormin = -1,
        [bigint]$errormax = -1,
        [string]$errormsg = $null,
        [int]$decimalmode = 0,
        [bool]$sensorwarning = $false,
        [bool]$limitmode = $false, 
        [bool]$showchart = $true

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


    $result += "</Result>"

    return $result
}

# Check if sensor already exists
function Check-SensorExists{
    param(
        [string]$sensorname
        )

    $sensorlist = (Get-Content $sensorlistfile)
        
    if(!$sensorlist -match $sensorname){
        Write-Output $sensorname | out-file -FilePath $sensorlistfile -Append
    }

}

# Get gneral array details
function Get-ArrayDetails{
    Show-Message "info" "Get Array Identification Details"

    try{
        $array = Invoke-RestMethod -Uri "$array/api/$apiversion/array" -websession $mysession -ContentType "application/json"
        $global:arrayname = $array[0].array_name
        $sensorlist = [string]::Format("{0}{1}-sensors.list", $scriptPath, $global:arrayname)
        if(!(Test-Path $sensorlist)){
            New-Item -ItemType File -Path $sensorlist | Out-Null
            Show-Message "info" "Created sensor list file: $($sensorlist)"
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
                                -value $arrayspace[0].data_reduction
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
                                -value ($arrayperf[0].usec_per_read_op / 1000) `
                                -unit "TimeResponse"
        $sensoroutput += Get-ResultElement `
                                -channel "Latency Write" `
                                -value ($arrayperf[0].usec_per_write_op / 1000) `
                                -unit "TimeResponse"
        $sensoroutput += Get-ResultElement `
                                -channel "IOPs Reads" `
                                -value $arrayperf[0].reads_per_sec
        $sensoroutput += Get-ResultElement `
                                -channel "IOPs Writes" `
                                -value $arrayperf[0].writes_per_sec
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
        $sensoroutput = $global:output      
        foreach($item in $hardware){
            $sensoroutput += Get-ResultElement `
                                    -channel $item.name `
                                    -value $hardware_status[$item.status] `
                                    -float 0 `
                                    -notifychanged $true `
                                    -valuelookup "prtg.standardlookups.purestorage.hardwarestatus" `
                                    -warningmax 2 `
                                    -errormax 8
        }
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
                                    -float 0 `
                                    -notifychanged $true `
                                    -valuelookup "prtg.standardlookups.purestorage.drivestatus" `
                                    -warningmax 4 `
                                    -errormax 8 `
                                    -showchart $false
            
            if($drive_status[$drive.status] -gt 3){$overallcondition = 6}
        }
        #$global:output += "<text>Drive Health</text>"
        $sensoroutput = $global:output + `
                        (Get-ResultElement `
                                -channel "Drives Overall" `
                                -value $overallcondition `
                                -float 0 `
                                -notifychanged $true `
                                -valuelookup "prtg.standardlookups.purestorage.drivestatus" `
                                -warningmax 4 `
                                -errormax 8) + $sensoroutput

        $sensoroutput += "</prtg>"

        Write-Host $sensoroutput
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
    "VOLUME"       {Get-VolumeStatus}
    "HOSTGROUP"    {Get-HostGroupPerf}
    default        {Get-ArrayPerformance}
}

$timer.Stop();

#Delete-Session
$mysession = $null



Show-Message "information" "Elapsed Time: $($timer.Elapsed)"

