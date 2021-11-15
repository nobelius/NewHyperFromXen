#############################################################
### WARNING: TAKE SNAPSHOT OF VM BEFORE USING THIS SCRIPT ###
### - Remote management MUST be enabled on remote server  ###
#############################################################

$credential = get-credential #You will be prompted for VM credentials

### Change these variables ###

 #IP of Windows Server
    $servername = "v18091402.vps.pin.se (nykael-srv01)" #This is VM-name, will be used as VMname in Hyper-V and naming of drives
    $wserver = "212.91.128.32"

 #Hyper-V preparation#
    $RAM = 8GB
    $CPU = 4

 #WHERE TO PLACE NEW VM
    $hvhost = "hv701"

##############################

# Preparation basics

#Make sure there isn't a VM with the same name already
Write-host "Just checking there isn't already a server with that name" -ForegroundColor Cyan
 $vmname = $servername

 Invoke-Command -ComputerName $hvhost -ArgumentList $vmname -ScriptBlock { 
    $checkifexist = get-vm -Name $using:vmname -ErrorAction SilentlyContinue

    if($checkifexist.VMName -eq $using:vmname){
         Write-host "There is already a VM with that name" -ForegroundColor Yellow
         Start-Sleep 2
         exit
    }
 } 
Write-host "Looks good!" -ForegroundColor Green    

Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$wserver" -Confirm:$true


#CHECK IFF WINDOWS HAS BOOTED FUNCTION
function checkifserverON{
######## 
$Count = 1
do 
{
Write-Host "Check if VM started Windows : $Count" -ForegroundColor Green
$result = Invoke-Command -ErrorAction SilentlyContinue -ComputerName $wserver -Credential $credential -ScriptBlock {whoami} 
    Start-Sleep -Seconds 1
    $Count++
} 
until ($result)
if ($result) {Write-Host "Executing config on $wserver" -ForegroundColor Green}{}
########
}

#Get actual hostname of server
$hostname = Invoke-Command -ComputerName $wserver -Credential $credential -ScriptBlock {

hostname
} 

$y = Read-Host -Prompt "Do you want to remove Xentools and Export on $hostname / $wserver ? y/n"

if($y -ne "y"){
exit
}

#STARTING WORK ON SERVER
$starttime = get-date


#Uninstall xen agent and reboot
    Write-host "Removing Xen Management Agent from $servername / $hostname" -ForegroundColor Yellow

Function removexentools{        
        Invoke-Command -ComputerName $wserver -Credential $credential -ArgumentList $servername -ScriptBlock {
            $b = Get-WmiObject -Class win32_product | Where Name -like "*Management Agent*"
                if($(($b) -eq $null) -eq $false){
                    Write "Removing Xen Management Agent from $using:servername"
                    $b.Uninstall()
                    Start-Sleep 10
                    Restart-Computer -force -ErrorAction SilentlyContinue
                } else {
                    Write-host "No agent installed, continuing" -ForegroundColor Red
                }
        }
}
removexentools
Start-Sleep 2
removexentools

checkifserverON

Invoke-Command -ComputerName $wserver -Credential $credential -ArgumentList $servername -ScriptBlock {
#Connect to fileshare#
$uncServer = "\\89.189.192.129"
$uncFullPath = "$uncServer\XenShare$"
$username = "infracom.internal\SA-XenShare"
$password = "9#^WSh61iqZ8@bQ"
Write-Host "Connecting to fileshare"
net use $uncServer $password /USER:$username 
Start-Sleep 2
    #REMOVING GHOST DEVICES
    Write "Removing ghost devices for xen"
        powershell.exe -noprofile -executionpolicy bypass -file "$uncFullPath\removeGhosts.ps1" -filterByClass @("LegacyDriver","Processor")
        start-sleep 1

        cd C:\windows\system32\drivers
        DIR Xen*.*
        DEL Xen*.*

        start-sleep 3
        restart-computer -force
        start-sleep 10
}
checkifserverON

Invoke-Command -ComputerName $wserver -Credential $credential -ArgumentList $servername -ScriptBlock {



#Connect to fileshare#
$uncServer = "\\89.189.192.129"
$uncFullPath = "$uncServer\XenShare$"
$username = "infracom.internal\SA-XenShare"
$password = "9#^WSh61iqZ8@bQ"
Write-Host "Connecting to fileshare"
net use $uncServer $password /USER:$username 
Start-Sleep 2

    #Download disk2vhd to C:\, DIDN't Work so now it gets the disk2vhd files from the xenshare instead   
    #Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Disk2vhd.zip" -OutFile 'C:\Disk2vhd.zip'
    #Start-Sleep 2

    #Unpack files
    if((Test-Path "C:\Disk2vhd\") -eq $false){
    Write "Adding disk2vhd files on server"
    New-Item -ItemType Directory "C:\Disk2vhd" -force
    Expand-Archive -LiteralPath "$uncFullPath\Disk2vhd.zip" -DestinationPath "C:\Disk2vhd\"
    }

$filename = $using:servername

Start-Sleep 10

CD C:\Disk2vhd\
.\disk2vhd.exe * "$uncFullPath\$filename.vhdx" /accepteula

    Start-Sleep 3

#Check if disk2vhd is still running
DO { 
 write "disk2vhd is running"
 Start-Sleep 15 }
 
 while(!(Get-Process -name *disk2*) -eq $false)

Write-host "Disks transfered to Mgmt server" -ForegroundColor Green
Start-Sleep 3

#Removing disk2vhd files
#Write-host "Cleaning up work files on server..." -ForegroundColor Cyan
Remove-Item "C:\Disk2vhd" -Force

#Disconnect fileshare
net use \\89.189.192.129\XenShare$ /d
net use "\\89.189.192.129\XenShare$" "badpassword" /user:"baduser"

Start-Sleep 1


} #End of invoke#




##########################################################################################


#Gets GPT or MBR and shuts down Xen VM
$diskstyle = Invoke-Command -ComputerName $wserver -Credential $credential -ScriptBlock {
    (gwmi -query "Select * from Win32_DiskPartition WHERE Index = 0 AND BootPartition = True" | Select-Object DiskIndex, @{Name="GPT";Expression={$_.Type.StartsWith("GPT")}}).GPT
}

#### THIS BYPASSES GEN CONVERTION ###
$diskstyle = $true
#####################################

##########################

$VMSTORE = "\\$hvhost\C$\ClusterStorage\Vol02\Hyper-V\Virtual Hard Disks"

$HardDisks = (GCI "S:\XenShare$\" | ? Name -like "$vmname*.vhdx").Name

foreach($disk in $HardDisks){
    # Copies VHDX from disk2vhd to Hard Disks folder
    Copy-Item "S:\XenShare$\$disk" -Destination "$VMSTORE\$disk"
}


#Determening which disk to mount first
If($HardDisks.Count -gt 1){
    $bootdisk = $HardDisks[0]
} else{
    $bootdisk = $HardDisks
}

# CREATE VM #

#Gen1 if MBR (False)
if($diskstyle -eq $false){
    $gen = [int]1
} else {
    $gen = [int]2
}


#Creating VM in correct GEN
Invoke-Command -ComputerName $hvhost -Credential $hvcred -ArgumentList $vmname, $HardDisks, $CPU, $RAM, $bootdisk, $gen, $credential, $diskstyle -ScriptBlock { 
 
    #New VM
    New-VM -Name $using:VmName -MemoryStartupBytes $using:RAM -VHDPath "C:\ClusterStorage\Vol02\Hyper-V\Virtual Hard Disks\$using:bootdisk" -Generation $using:gen

    #Setting CPU and disables checkpoints
    Write-host "Setting CPU"
    Set-VM $using:vmname -ProcessorCount $using:cpu
    Write-host "Disable automatic checkpoints"
    Set-VM -Name $using:vmname -AutomaticCheckpointsEnabled $false
    
    Write-host "Starting VM $using:vmname"
    Start-VM $using:vmname


#Add rest of the drives then boots VM
$restofdrives = $using:HardDisks | Where-Object { $_ -ne $using:bootdisk }

    foreach($disk in $restofdrives){
        Add-VMHardDiskDrive -VMName $using:vmname -Path "C:\ClusterStorage\Vol02\Hyper-V\Virtual Hard Disks\$disk"
        Start-VM $using:vmname
    }



#End of HyperV-Host invoke
}



$endtime = get-date
$totaltime = $endtime - $starttime
Write-host $("It took: "+$totaltime.Hours+" hours,"+$totaltime.Minutes+" min, "+$totaltime.Seconds+"s to deliver custom VM")