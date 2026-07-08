#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [+] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    [!] $msg" -ForegroundColor Yellow }

# ============================================================
# BLOCK 1 — Accounts
# ============================================================
Write-Step "Block 1: Creating accounts"

# Enable Administrator
net user Administrator /active:yes | Out-Null
net user Administrator "Admin@Lab2026!" | Out-Null
Write-OK "Administrator enabled"

$accounts = @(
    @{ Name="diana";          Password="lab";       FullName="Diana" },
    @{ Name="Alex";           Password="Qaz@1234";  FullName="Alex" },
    @{ Name="enterpriseuser"; Password="Wsx@1234";  FullName="Enterprise User" },
    @{ Name="enterpriseadmin";Password="Edc@1234";  FullName="Enterprise Admin" }
)

foreach ($acc in $accounts) {
    try {
        Get-LocalUser -Name $acc.Name -ErrorAction Stop | Out-Null
        Set-LocalUser -Name $acc.Name -Password (ConvertTo-SecureString $acc.Password -AsPlainText -Force)
        Write-OK "Updated: $($acc.Name)"
    } catch {
        $secPwd = ConvertTo-SecureString $acc.Password -AsPlainText -Force
        New-LocalUser -Name $acc.Name -Password $secPwd -FullName $acc.FullName -PasswordNeverExpires | Out-Null
        Write-OK "Created: $($acc.Name)"
    }
}

# ============================================================
# BLOCK 2 — Group Membership
# ============================================================
Write-Step "Block 2: Group membership"

# Create custom group
try {
    New-LocalGroup -Name "Remote Desktop Manager" -Description "Remote Desktop Managers" | Out-Null
    Write-OK "Group 'Remote Desktop Manager' created"
} catch {
    Write-Warn "Group 'Remote Desktop Manager' already exists"
}

$groupMap = @{
    "Remote Desktop Manager" = @("diana")
    "Remote Desktop Users"   = @("diana")
    "Remote Management Users"= @("Alex")
    "Backup Operators"       = @("enterpriseuser")
    "Administrators"         = @("enterpriseadmin")
}

foreach ($grp in $groupMap.Keys) {
    foreach ($usr in $groupMap[$grp]) {
        try {
            Add-LocalGroupMember -Group $grp -Member $usr -ErrorAction Stop
            Write-OK "$usr -> $grp"
        } catch {
            Write-Warn "$usr already in $grp (or error: $($_.Exception.Message))"
        }
    }
}

# ============================================================
# BLOCK 3 — SeShutdownPrivilege: deny diana
# ============================================================
Write-Step "Block 3: Deny diana shutdown privilege"

$seceditInf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeShutdownPrivilege = *S-1-5-32-544,*S-1-5-32-551
"@

# SeShutdownPrivilege default: Administrators(544), Backup Operators(551)
# diana intentionally excluded

$infPath = "$env:TEMP\deny_shutdown.inf"
$dbPath  = "$env:TEMP\deny_shutdown.sdb"
$seceditInf | Out-File -FilePath $infPath -Encoding Unicode
secedit /configure /db $dbPath /cfg $infPath /areas USER_RIGHTS /quiet
Write-OK "SeShutdownPrivilege: Administrators + Backup Operators only (diana excluded)"

# ============================================================
# BLOCK 4 — C:\Services folder
# ============================================================
Write-Step "Block 4: C:\Services directory"

if (-not (Test-Path "C:\Services")) {
    New-Item -ItemType Directory -Path "C:\Services" | Out-Null
}

# Authenticated Users = Modify (read+write+execute+delete, no full control)
icacls "C:\Services" /grant "NT AUTHORITY\Authenticated Users:(OI)(CI)M" | Out-Null
Write-OK "C:\Services created with Authenticated Users:Modify"

# ============================================================
# BLOCK 5 — Compile EnterpriseService.exe
# ============================================================
Write-Step "Block 5: Compiling EnterpriseService.exe"

$csharpSrc = @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.ServiceProcess;

public class EnterpriseService : ServiceBase {

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr LoadLibrary(string lpFileName);

    public EnterpriseService() { ServiceName = "EnterpriseService"; }

    protected override void OnStart(string[] args) {
        // Bare name triggers Windows DLL search order:
        // 1. exe directory (C:\Services\)  <- hijack point
        // 2. System32, Windows, CWD, %PATH%
        LoadLibrary("EnterpriseServiceOptional.dll");
    }

    protected override void OnStop() { }

    static void Main() {
        ServiceBase.Run(new EnterpriseService());
    }
}
'@

$srcPath = "$env:TEMP\EnterpriseService.cs"
$exePath = "C:\Services\EnterpriseService.exe"
$csharpSrc | Out-File -FilePath $srcPath -Encoding UTF8

# Find csc.exe
$cscPath = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64" -Filter "csc.exe" -Recurse -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName

if (-not $cscPath) {
    # Fallback: copy cmd.exe as placeholder
    Write-Warn "csc.exe not found. Copying cmd.exe as placeholder."
    Copy-Item "$env:SystemRoot\System32\cmd.exe" $exePath -Force
} else {
    & $cscPath /out:$exePath /target:exe "$srcPath" 2>&1 | Out-Null
    Write-OK "Compiled: $exePath (using $cscPath)"
}

# Set explicit ACL on EnterpriseService.exe
icacls $exePath /inheritance:r | Out-Null
icacls $exePath /grant "NT AUTHORITY\SYSTEM:(F)" | Out-Null
icacls $exePath /grant "BUILTIN\Administrators:(F)" | Out-Null
icacls $exePath /grant "BUILTIN\Users:(RX)" | Out-Null
Write-OK "ACL set: SYSTEM(F), Administrators(F), Users(RX)"

# ============================================================
# BLOCK 6 — Log file
# ============================================================
Write-Step "Block 6: EnterpriseServiceLog.log"

$logContent = "[00:00:00.000] (e08) WARN   Couldn't load EnterpriseServiceOptional.dll, only using basic features."
$logContent | Out-File -FilePath "C:\Services\EnterpriseServiceLog.log" -Encoding UTF8 -NoNewline
Write-OK "Log file created"

# ============================================================
# BLOCK 7 — Create Windows Service
# ============================================================
Write-Step "Block 7: Creating EnterpriseService Windows service"

# Remove if exists
$existSvc = Get-Service -Name "EnterpriseService" -ErrorAction SilentlyContinue
if ($existSvc) {
    if ($existSvc.Status -eq "Running") {
        Stop-Service -Name "EnterpriseService" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    sc.exe delete EnterpriseService | Out-Null
    Start-Sleep -Seconds 2
    Write-Warn "Old EnterpriseService removed"
}

sc.exe create EnterpriseService binPath= "C:\Services\EnterpriseService.exe" `
    obj= ".\enterpriseuser" password= "Wsx@1234" start= auto `
    DisplayName= "Enterprise Service" | Out-Null

# Grant SeServiceLogonRight via LSA API (immediate, no reboot/gpupdate needed)
$lsaCode = @'
using System;
using System.Runtime.InteropServices;

public class LsaUtil {
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES Attributes, uint Access, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaAddAccountRights(IntPtr PolicyHandle, IntPtr AccountSid, LSA_UNICODE_STRING[] UserRights, int CountOfRights);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr ObjectHandle);
    [DllImport("advapi32.dll")]
    static extern uint LsaNtStatusToWinError(uint Status);

    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; [MarshalAs(UnmanagedType.LPWStr)] public string Buffer; }

    public static void AddPrivilege(System.Security.Principal.SecurityIdentifier sid, string privilege) {
        byte[] sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);
        IntPtr sidPtr = Marshal.AllocHGlobal(sidBytes.Length);
        Marshal.Copy(sidBytes, 0, sidPtr, sidBytes.Length);
        LSA_OBJECT_ATTRIBUTES attr = new LSA_OBJECT_ATTRIBUTES();
        attr.Length = Marshal.SizeOf(attr);
        IntPtr policy;
        uint r = LsaOpenPolicy(IntPtr.Zero, ref attr, 0x00020000 | 0x00000800, out policy);
        if (r != 0) throw new Exception("LsaOpenPolicy error: " + LsaNtStatusToWinError(r));
        LSA_UNICODE_STRING[] rights = new LSA_UNICODE_STRING[1];
        rights[0] = new LSA_UNICODE_STRING { Buffer = privilege, Length = (ushort)(privilege.Length * 2), MaximumLength = (ushort)((privilege.Length + 1) * 2) };
        r = LsaAddAccountRights(policy, sidPtr, rights, 1);
        LsaClose(policy);
        Marshal.FreeHGlobal(sidPtr);
        if (r != 0) throw new Exception("LsaAddAccountRights error: " + LsaNtStatusToWinError(r));
    }
}
'@
Add-Type -TypeDefinition $lsaCode -Language CSharp

$euSid = (New-Object System.Security.Principal.NTAccount("enterpriseuser")).Translate([System.Security.Principal.SecurityIdentifier])
[LsaUtil]::AddPrivilege($euSid, "SeServiceLogonRight")
Write-OK "EnterpriseService created, enterpriseuser granted SeServiceLogonRight"

# ============================================================
# BLOCK 8 — Service DACL
# ============================================================
Write-Step "Block 8: Setting service DACL"

# Get SIDs
$dianaSid = (New-Object System.Security.Principal.NTAccount("diana")).Translate([System.Security.Principal.SecurityIdentifier]).Value
$alexSid  = (New-Object System.Security.Principal.NTAccount("Alex")).Translate([System.Security.Principal.SecurityIdentifier]).Value

# SDDL breakdown:
#   D:  = DACL
#   (A;;...;;;SY)  SYSTEM - full rights
#   (A;;...;;;BA)  Administrators - full rights
#   (A;;CCLCSWRPLOCRRC;;;alexSID) - Alex: start(RP), stop(WP), query(LC,SW,LO,CR,RC)
#   (D;;RPWPRC;;;dianaSID) - diana: DENY start/stop/ReadControl (blocks sc sdshow)

$sddl = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPLOCRRC;;;$alexSid)(D;;RPWPRC;;;$dianaSid)"

# Stop service first (required for sdset)
Stop-Service -Name "EnterpriseService" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$sdResult = sc.exe sdset EnterpriseService $sddl
Write-OK "Service DACL set"
Write-OK "  diana SID: $dianaSid (DENY start/stop/ReadControl)"
Write-OK "  Alex  SID: $alexSid  (ALLOW start/stop/query)"

# ============================================================
# BLOCK 9 — diana's notes
# ============================================================
Write-Step "Block 9: diana's note files"

$dianaHome = "C:\Users\diana"
if (-not (Test-Path $dianaHome)) {
    New-Item -ItemType Directory -Path $dianaHome | Out-Null
}

# Set ACL
$acl = Get-Acl $dianaHome
$acl.SetAccessRuleProtection($false, $true)
$rules = @(
    [System.Security.AccessControl.FileSystemAccessRule]::new("diana","FullControl","ContainerInherit,ObjectInherit","None","Allow"),
    [System.Security.AccessControl.FileSystemAccessRule]::new("NT AUTHORITY\SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow"),
    [System.Security.AccessControl.FileSystemAccessRule]::new("BUILTIN\Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")
)
foreach ($r in $rules) { $acl.AddAccessRule($r) }
Set-Acl -Path $dianaHome -AclObject $acl

# Create 22 note files with filler
for ($i = 1; $i -le 22; $i++) {
    $filePath = "$dianaHome\note$i.txt"
    "This is note file number $i." | Out-File -FilePath $filePath -Encoding UTF8
}

# Override specific files
"password reset default is Qaz@1234" | Out-File -FilePath "$dianaHome\note19.txt" -Encoding UTF8 -NoNewline
"alex were reset password"           | Out-File -FilePath "$dianaHome\note21.txt" -Encoding UTF8 -NoNewline
Write-OK "22 note files created in $dianaHome"

# ============================================================
# BLOCK 10 — WinRM + Pass-The-Hash
# ============================================================
Write-Step "Block 10: WinRM + Pass-The-Hash setup"

try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Write-OK "PSRemoting enabled"
} catch {
    Write-Warn "PSRemoting: $($_.Exception.Message)"
}

# LocalAccountTokenFilterPolicy = 1 → allows PTH for local accounts via WinRM
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $regPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord
Write-OK "LocalAccountTokenFilterPolicy = 1 (PTH enabled for local accounts)"

# Ensure WinRM firewall rule open
try {
    netsh advfirewall firewall add rule name="WinRM HTTP" protocol=TCP dir=in localport=5985 action=allow | Out-Null
    Write-OK "Firewall: WinRM port 5985 open"
} catch {
    Write-Warn "Firewall rule may already exist"
}

# ============================================================
# START SERVICE (after all privilege grants have propagated)
# ============================================================
Start-Sleep -Seconds 3
$startErr = $null
Start-Service -Name "EnterpriseService" -ErrorAction SilentlyContinue -ErrorVariable startErr
if ($startErr) {
    Write-Warn "Service start attempt 1 failed: $startErr"
    Start-Sleep -Seconds 5
    Start-Service -Name "EnterpriseService" -ErrorAction SilentlyContinue -ErrorVariable startErr
    if ($startErr) {
        Write-Warn "Service start attempt 2 failed: $startErr"
    } else {
        Write-OK "EnterpriseService started (attempt 2)"
    }
} else {
    Write-OK "EnterpriseService started"
}

# ============================================================
# DONE
# ============================================================
Write-Host "`n[+] Lab setup complete." -ForegroundColor Green
Write-Host "    Verify with: Get-Service EnterpriseService" -ForegroundColor Gray
Write-Host "    PTH test:     evil-winrm -i <IP> -u Administrator -H <NTLM>" -ForegroundColor Gray
