PGS Kiosk Manager 4.0
Full instructions: PGS-Kiosk-Manager-Guide.pdf

Turns individual restrictions on or off for standard (non-administrator) local
accounts on Windows 10/11. Windows PowerShell 5.1 + WinForms, no install needed.

START
1. Extract the ZIP to a folder (for example C:\Tools\PGS-Kiosk-Manager).
2. Double-click Launch-PGS-Kiosk-Manager.cmd and accept the administrator prompt.
3. Click a user: the checkboxes show that user's current restrictions.
4. Tick/untick what you want, then "Apply to selected users".
   Apply makes the selected users match the checkboxes exactly
   (checked = ON, unchecked = OFF). You can select several users at once.

RESTRICTIONS
- Hide drive icons in This PC (personal folders stay accessible)
- Disable Task Manager
- Disable Command Prompt (batch/logon scripts still run)
- Block Settings app and Control Panel
- Remove Run (Win+R) from Start menu
- Disable Registry Editor
- Prevent changing the desktop wallpaper
- Block Microsoft Store (Store policy + a per-user AppLocker rule; see below)
- Block a list of programs you choose (default: PowerShell, cmd, Terminal,
  regedit, reg, MMC). Editable in the text box.
To add more restrictions, add an entry to $PgsFeatures in PGS-Engine.ps1.

BACKUPS
Before every Apply / Turn off / Restore, the user's current values are saved to
  C:\ProgramData\PGS-Kiosk-Manager\Backups\<user>\<user>-<date>-before-<action>.json
"Restore from backup..." puts a user back exactly as a backup file recorded.
Backups from v3.0 can also be restored. A log is kept in
  C:\ProgramData\PGS-Kiosk-Manager\pgs.log
The folder is readable by Administrators and SYSTEM only.

SIGNED-IN USERS
Works best when the user is signed out. If they are signed in, the changes are
written to their live settings and fully apply after they sign out and back in.
A user who has never signed in has no profile yet: sign in as them once first.

COMMAND LINE (elevated PowerShell)
  .\PGS-Engine.ps1 -Action Users
  .\PGS-Engine.ps1 -Action Inspect -UserName PaulS
  .\PGS-Engine.ps1 -Action Apply   -UserName PaulS,HayleyM -Enable TaskManager,RunMenu,Store,ShellBlock
  .\PGS-Engine.ps1 -Action Clear   -UserName PaulS
  .\PGS-Engine.ps1 -Action Restore -UserName PaulS -BackupFile <path to .json>

MICROSOFT STORE
The Store block sets the per-user Store policy and adds an AppLocker rule that
denies the Microsoft Store app to that user's SID only. AppLocker works on
Windows Pro, Enterprise and Education, not Home. The first time it is used, the
tool turns on AppLocker packaged-app rules for the PC together with the standard
"allow all signed packaged apps" rule, so other users and apps are unaffected.
It also starts the Application Identity (AppIDSvc) service.

LIMITATIONS
- Per-user policies, not a security-grade single-app kiosk. Program blocking
  only stops launches through Explorer (Start menu, desktop, double-click).
- Local Group Policy, MDM/Intune or other management tools can override these.
- Windows Home may ignore some policies. Test each restriction on one account.
- Keep a separate working Administrator account at all times.
