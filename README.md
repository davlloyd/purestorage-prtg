
#Pure Storage
## PRTG Sensor

Author:     lloydy@purestorage.com
Version:    1.00


This sensor allows selective monitoring of **FlashArray** components as required. 

---

Supported components include:

- Array Capacity and consumption details
- Array Performance details
- Hardware components health status
- Drive health status
- Volume performance details (coming soon)
- Host group performance details (coming soon)

--- 
Each of the scope options has its own sensor and then multiple channels. This is required due to the supported sensor maximum of 50 channels per sensor (not enforced). Currently the inclusion of the **volume** and **hostgroup** sensors is being asssessed as they have sensor lifecylce considerations due to the dynamic additon, remova, and instance totals that these elements entail.

---

##Installation Instructions


**Written for Purity REST API 1.6**

- Copy the script file into the PRTG Custom EXEXML sensor directory C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML
    - Get-PureFA-Sensor.ps1 (PowerShell Sensor Script)
- Copy the Lookup files into the PRTG lookup file directory C:\Program Files (x86)\PRTG Network Monitor\lookups\custom
    - prtg.standardlookups.purestorage.drivestatus.ovl (Drive status value lookup file)      
    - prtg.standardlookups.purestorage.hardwarestatus.ovl (Hardware status value lookup file)
- Restart the 'PRTG Core Server Service' windows service to load the custom lookup files
- Create Sensor Custom EXE/ Script Advanced Sensor for each sensor you wish to monitor (refer Scope) and give it a meaniful name
- Set Parameters for sensor
    - (ArrayAddress) Target Array management DNS name or IP address
    - (UserName) and (Password) or (APIKey) to gain access 
    - (Scope) to set which element to monitor with Sensor
   e.g. -arrayaddress '%host' -scope 'hardware' -apikey '3bdf3b60-f0c0-fa8a-83c1-b794ba8f562c'



---

##Operational Scopes

The scope defines the details to be monitored from the array
Supported Scope Values:

-   Capacity
-   Performance      
-   Hardware
-   Drive
-   Volume (not currently supported)
-   HostGroup (not currently supported)
