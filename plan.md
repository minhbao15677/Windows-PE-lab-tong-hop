# Plan: Windows Privilege Escalation Lab Setup

> **Sau khi tạo script xong hãy tự động chạy script và sửa lỗi nếu có.**

---

## Script: `setup-lab.ps1` — chạy với quyền Administrator

---

## Block 1 — Tạo tài khoản

- Enable built-in Administrator, đặt password mạnh (students dùng PTH, không dùng plaintext)
- `New-LocalUser` cho: diana (lab), Alex (Qaz@1234), enterpriseuser (Wsx@1234), enterpriseadmin (Edc@1234)

## Block 2 — Group Membership

- `New-LocalGroup "Remote Desktop Manager"` (custom group)
- diana → Remote Desktop Manager + Remote Desktop Users (cần cả hai cho RDP)
- Alex → Remote Management Users
- enterpriseuser → Backup Operators
- enterpriseadmin → Administrators

## Block 3 — Deny diana Shutdown Privilege

- Export current secedit policy → edit INF → set `SeShutdownPrivilege` không có SID của diana → reimport via `secedit /configure`

## Block 4 — Thư mục C:\Services

- `New-Item C:\Services`
- ACL: add `NT AUTHORITY\Authenticated Users` = Modify (icacls hoặc Set-Acl)
- Giữ nguyên SYSTEM/Administrators defaults

## Block 5 — EnterpriseService.exe

- Viết minimal C# Windows Service source ra temp file
- Tìm `csc.exe` trong `C:\Windows\Microsoft.NET\Framework64\`
- Compile → `C:\Services\EnterpriseService.exe`
- Strip inherited ACL, set explicit:
  - `NT AUTHORITY\SYSTEM:(F)`
  - `BUILTIN\Administrators:(F)`
  - `BUILTIN\Users:(RX)` — không có write/modify

## Block 6 — Log File

- Ghi `C:\Services\EnterpriseServiceLog.log` với nội dung:
  ```
  [00:00:00.000] (e08) WARN   Couldn't load EnterpriseServiceOptional.dll, only using basic features.
  ```

## Block 7 — Windows Service

```
sc.exe create EnterpriseService binPath= "C:\Services\EnterpriseService.exe" obj= ".\enterpriseuser" password= "Wsx@1234" start= auto
```
- Grant enterpriseuser `SeServiceLogonRight` via secedit INF

## Block 8 — Service DACL

- Lấy SID của diana + Alex động qua `[System.Security.Principal.NTAccount]::Translate()`
- Build SDDL string:
  - `(A;;CLCSWRPWPDTLOCRRC;;;SY)` — SYSTEM full
  - `(A;;CDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)` — Administrators full
  - `(A;;CCLCSWRPLOCRRC;;;alexSID)` — Alex: start(RP) + stop(WP) + query read
  - `(D;;RPWPRC;;;dianaSID)` — diana: **deny** start, stop, READ_CONTROL (blocks `sc sdshow`)
- `sc.exe sdset EnterpriseService "<SDDL>"`

## Block 9 — diana's Notes

- Tạo `C:\Users\diana` folder, set ACL (diana=FullControl, SYSTEM=FullControl, Admins=FullControl)
- Loop tạo `note1.txt` → `note22.txt` với filler content
- Overwrite `note19.txt` → `"password reset default is Qaz@1234"`
- Overwrite `note21.txt` → `"alex were reset password"`

## Block 10 — WinRM + Pass-The-Hash

```powershell
Enable-PSRemoting -Force
# Cho phép PTH cho local accounts:
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord
# Firewall rule cho WinRM đã được tạo bởi Enable-PSRemoting
```

---

## Rủi ro / Lưu ý

| Vấn đề | Cách xử lý |
|---|---|
| C# compile thất bại nếu không có .NET Framework | Fallback: copy `cmd.exe` làm placeholder (service không start nhưng structure còn) |
| `sc sdset` cần service dừng trước | Stop service trước khi sdset |
| diana home dir conflict nếu đã login trước | Script overwrite ACL |
| ServiceLogonRight chưa được cấp | Thêm via secedit INF trong Block 7 |
| SAM/SYSTEM dump — không cần setup thêm | Backup Operators có SeBackupPrivilege theo mặc định; hashes có sẵn |
