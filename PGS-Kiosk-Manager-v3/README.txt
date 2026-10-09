PGS Kiosk Manager 3.0 - PORTABLE PILOT

For local standard accounts on Windows 11. Administrator must launch the app.
Works with local account names on any Windows 11 machine where the local-account PowerShell cmdlets exist.
Windows PowerShell 5.1 and WinForms are required; not a compiled EXE.

BEFORE USE
1. Keep a working separate Administrator account.
2. Sign restricted users out completely.
3. Extract ZIP to a folder writable only by Administrators.
4. Right-click Launch-PGS-Kiosk-Manager.cmd > Run as administrator.
5. Inspect one account and test on a disposable Windows 11 laptop first.

FUNCTIONS
- Inspect: read-only view of managed registry values.
- Apply: save current settings to a JSON backup and apply selected controls.
- Clear: save snapshot then clear the PGS-managed settings (maintenance).
- Restore: restore a specifically selected VERSION 3 JSON backup (not older v2 JSON).
- Multiple users: selections supported for Apply and Clear.

BACKUPS: C:\ProgramData\PGS-Kiosk-Manager\Backups
Backups represent the state *immediately before* that operation, which might already be restricted.
Select a known clean snapshot or use Clear to relax all PGS-managed restrictions.

LIMITATIONS
- Not a security-grade single-app kiosk. Explorer block-list only limits typical launches.
- Does not configure or block Microsoft Store. AppLocker Store enforcement is a separate security-sensitive task that needs tested rules and machine-wide configuration.
- Does NOT configure 'Run only specified Windows applications' (RestrictRun). This setting can break Windows App and is left unchanged.
- Does NOT configure NoViewOnDrive, because it breaks access to user folders. Existing NoViewOnDrive is not removed automatically; remove it by inspecting that policy or with a targeted repair.
- Settings can be overridden by Local Group Policy, MDM, or other management software.
- Maintenance restoration is MANUAL. No timed auto-restore is promised.
- Does not migrate legacy PGS v2 backups.
- Does not overwrite non-PGS app-block lists; intervention is required if they exist.
- Registry unload failures are reported and the affected mount is not forcibly deleted.
- Windows11 Home may not enforce every policy. Test outcomes account by account.

CAUTION
Recreating Windows profiles deletes their local data/settings and is not required to use this app.
Do not delete user accounts until you have confirmed no files/credentials are needed and backups exist.
