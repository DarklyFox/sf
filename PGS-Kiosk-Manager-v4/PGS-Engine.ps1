# PGS Kiosk Manager 4.0 - per-user restriction engine (Windows PowerShell 5.1)
#
# The GUI dot-sources this file to get its functions. It can also be used from an
# elevated PowerShell prompt:
#   .\PGS-Engine.ps1 -Action Users
#   .\PGS-Engine.ps1 -Action Inspect -UserName PaulS
#   .\PGS-Engine.ps1 -Action Apply   -UserName PaulS,HayleyM -Enable TaskManager,RunMenu
#   .\PGS-Engine.ps1 -Action Clear   -UserName PaulS
#   .\PGS-Engine.ps1 -Action Restore -UserName PaulS -BackupFile C:\ProgramData\PGS-Kiosk-Manager\Backups\PaulS\file.json
# Apply turns ON the features named in -Enable and turns OFF every other feature.
param(
 [ValidateSet('Library','Users','Inspect','Apply','Clear','Restore')][string]$Action='Library',
 [string[]]$UserName=@(),
 [string[]]$Enable=@(),
 [string[]]$BlockedApps=@(),
 [string]$BackupFile=''
)

$PgsRoot=Join-Path $env:ProgramData 'PGS-Kiosk-Manager'
$PgsBackupDir=Join-Path $PgsRoot 'Backups'
$PgsLogFile=Join-Path $PgsRoot 'pgs.log'

$PolExplorer='Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$PolSystem='Software\Microsoft\Windows\CurrentVersion\Policies\System'
$PolDesktop='Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
$PolCmd='Software\Policies\Microsoft\Windows\System'

# Every feature the tool manages. To add one, add an entry here: each Regs item is a
# DWORD written under the user's hive when the feature is ON and deleted when OFF.
$PgsFeatures=[ordered]@{
 HideDrives   =@{Label='Hide drive icons in This PC (personal folders stay accessible)'; Regs=@(@{Sub=$PolExplorer;Name='NoDrives';Data=67108863})}
 TaskManager  =@{Label='Disable Task Manager'; Regs=@(@{Sub=$PolSystem;Name='DisableTaskMgr';Data=1})}
 CommandPrompt=@{Label='Disable Command Prompt (batch/logon scripts still run)'; Regs=@(@{Sub=$PolCmd;Name='DisableCMD';Data=2})}
 ControlPanel =@{Label='Block Settings app and Control Panel'; Regs=@(@{Sub=$PolExplorer;Name='NoControlPanel';Data=1})}
 RunMenu      =@{Label='Remove Run (Win+R) from Start menu'; Regs=@(@{Sub=$PolExplorer;Name='NoRun';Data=1})}
 RegistryTools=@{Label='Disable Registry Editor'; Regs=@(@{Sub=$PolSystem;Name='DisableRegistryTools';Data=1})}
 Wallpaper    =@{Label='Prevent changing the desktop wallpaper'; Regs=@(@{Sub=$PolDesktop;Name='NoChangingWallPaper';Data=1})}
 ShellBlock   =@{Label='Block the programs listed below (Explorer launch block, best effort)'; Regs=@(@{Sub=$PolExplorer;Name='DisallowRun';Data=1}); List="$PolExplorer\DisallowRun"}
}
$PgsDefaultBlocked=@('powershell.exe','powershell_ise.exe','pwsh.exe','cmd.exe','wt.exe','regedit.exe','reg.exe','mmc.exe')

function Write-PgsLog([string]$Message) {
 try {
  New-Item -ItemType Directory -Force -Path $PgsRoot | Out-Null
  Add-Content -LiteralPath $PgsLogFile -Value ('{0}  {1}' -f (Get-Date -Format 's'),$Message) -Encoding UTF8
 } catch {}
}

# Runs a native exe without letting its stderr become a PowerShell terminating error.
function Invoke-PgsNative([string]$Exe,[string[]]$Arguments) {
 $previous=$ErrorActionPreference; $ErrorActionPreference='Continue'
 try { $out=@(& $Exe @Arguments 2>&1 | ForEach-Object {"$_"}); $code=$LASTEXITCODE }
 finally { $ErrorActionPreference=$previous }
 [pscustomobject]@{ExitCode=$code;Output=(($out -join ' ').Trim())}
}

function Test-PgsAdmin {
 ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PgsAdminSids {
 $sids=@{}
 try {
  Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object {if($_.SID){$sids[$_.SID.Value]=$true}}
 } catch {
  # Get-LocalGroupMember fails when the group holds orphaned or cloud members; use ADSI instead.
  $groupName=(New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
  $group=[ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
  foreach($member in @($group.psbase.Invoke('Members'))) {
   try {
    $bytes=$member.GetType().InvokeMember('objectSid','GetProperty',$null,$member,$null)
    $sids[(New-Object Security.Principal.SecurityIdentifier($bytes,0)).Value]=$true
   } catch {}
  }
 }
 $sids
}

# Enabled local accounts that are not administrators (built-in Administrator, Guest,
# DefaultAccount and WDAGUtilityAccount are always excluded).
function Get-PgsUsers {
 $admins=Get-PgsAdminSids
 $loaded=@([Microsoft.Win32.Registry]::Users.GetSubKeyNames())
 $profiles=@{}
 Get-CimInstance Win32_UserProfile | ForEach-Object {$profiles[$_.SID]=$_.LocalPath}
 Get-LocalUser | Where-Object {$_.Enabled -and -not $admins.ContainsKey($_.SID.Value) -and $_.SID.Value -notmatch '-(500|501|503|504)$'} |
  Sort-Object Name | ForEach-Object {
   $sid=$_.SID.Value; $path=$profiles[$sid]; $hasProfile=$false
   if($path){$hasProfile=Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT')}
   [pscustomobject]@{Name=$_.Name;SID=$sid;ProfilePath=$path;HasProfile=$hasProfile;SignedIn=($loaded -contains $sid)}
  }
}

function Get-PgsUser([string]$Name) {
 $found=@(Get-PgsUsers | Where-Object {$_.Name -eq $Name})
 if($found.Count -eq 0){throw "User '$Name' was not found, is disabled, or is an administrator. Only enabled standard local users can be managed."}
 $found[0]
}

# Runs $Body with the name of the user's hive under HKEY_USERS. A signed-in user's live
# hive is used directly; otherwise NTUSER.DAT is loaded temporarily and unloaded after.
function Invoke-PgsWithHive($User,[scriptblock]$Body) {
 if(@([Microsoft.Win32.Registry]::Users.GetSubKeyNames()) -contains $User.SID) {
  return (& $Body $User.SID $true)
 }
 if(-not $User.HasProfile){throw "$($User.Name) has no Windows profile yet. Sign in as $($User.Name) once, sign out, then try again."}
 $pgsFile=Join-Path $User.ProfilePath 'NTUSER.DAT'
 $pgsMount='PGS_'+[guid]::NewGuid().ToString('N').Substring(0,12)
 $pgsLoad=Invoke-PgsNative "$env:windir\System32\reg.exe" @('load',"HKU\$pgsMount",$pgsFile)
 if($pgsLoad.ExitCode -ne 0){throw "Could not open the registry of $($User.Name) ($pgsFile): $($pgsLoad.Output) Make sure $($User.Name) is fully signed out (Task Manager > Users > Sign off), or restart the PC."}
 try { & $Body $pgsMount $false }
 finally {
  $pgsOk=$false
  for($pgsTry=0; $pgsTry -lt 10 -and -not $pgsOk; $pgsTry++) {
   [gc]::Collect(); [gc]::WaitForPendingFinalizers()
   $pgsUnload=Invoke-PgsNative "$env:windir\System32\reg.exe" @('unload',"HKU\$pgsMount")
   if($pgsUnload.ExitCode -eq 0){$pgsOk=$true}else{Start-Sleep -Milliseconds 500}
  }
  if(-not $pgsOk) {
   Write-PgsLog "WARNING: could not unload HKU\$pgsMount for $($User.Name): $($pgsUnload.Output)"
   Write-Warning "Could not release the temporary registry copy of $($User.Name) (HKU\$pgsMount). Restart the PC before $($User.Name) signs in."
  }
 }
}

function Get-PgsRegValue([string]$Hive,[string]$Sub,[string]$Name) {
 $key=[Microsoft.Win32.Registry]::Users.OpenSubKey("$Hive\$Sub",$false)
 if($null -eq $key){return $null}
 try {
  if(@($key.GetValueNames()) -notcontains $Name){return $null}
  $kind=$key.GetValueKind($Name).ToString()
  $data=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if($kind -eq 'Binary'){$data=[Convert]::ToBase64String([byte[]]$data)}
  return [pscustomobject]@{Kind=$kind;Data=$data}
 } finally { $key.Dispose() }
}

function Set-PgsRegValue([string]$Hive,[string]$Sub,[string]$Name,[string]$Kind,$Data) {
 if($Kind -eq 'DWord'){$n=[int64]$Data; if($n -gt [int32]::MaxValue){$n-=4294967296}; $Data=[int32]$n}
 elseif($Kind -eq 'QWord'){$Data=[int64]$Data}
 elseif($Kind -eq 'MultiString'){$Data=[string[]]@($Data)}
 elseif($Kind -eq 'Binary'){$Data=[Convert]::FromBase64String([string]$Data)}
 else{$Data=[string]$Data}
 $key=[Microsoft.Win32.Registry]::Users.CreateSubKey("$Hive\$Sub")
 try { $key.SetValue($Name,$Data,[Microsoft.Win32.RegistryValueKind]$Kind) } finally { $key.Dispose() }
}

function Remove-PgsRegValue([string]$Hive,[string]$Sub,[string]$Name) {
 $key=[Microsoft.Win32.Registry]::Users.OpenSubKey("$Hive\$Sub",$true)
 if($null -ne $key){ try { $key.DeleteValue($Name,$false) } finally { $key.Dispose() } }
}

# Returns the string values of a key as an ordered dictionary, or $null if the key is missing.
function Get-PgsRegList([string]$Hive,[string]$Sub) {
 $key=[Microsoft.Win32.Registry]::Users.OpenSubKey("$Hive\$Sub",$false)
 if($null -eq $key){return $null}
 try {
  $items=[ordered]@{}
  foreach($n in $key.GetValueNames()){if($n){$items[$n]=[string]$key.GetValue($n)}}
  return $items
 } finally { $key.Dispose() }
}

function Remove-PgsRegKey([string]$Hive,[string]$Sub) {
 [Microsoft.Win32.Registry]::Users.DeleteSubKeyTree("$Hive\$Sub",$false)
}

function Get-PgsSnapshot([string]$Hive,$User) {
 $values=@(); $lists=@()
 foreach($feature in $PgsFeatures.Values) {
  foreach($reg in $feature.Regs) {
   $cur=Get-PgsRegValue $Hive $reg.Sub $reg.Name
   if($cur){$values+=[pscustomobject]@{Sub=$reg.Sub;Name=$reg.Name;Present=$true;Kind=$cur.Kind;Data=$cur.Data}}
   else{$values+=[pscustomobject]@{Sub=$reg.Sub;Name=$reg.Name;Present=$false;Kind='';Data=$null}}
  }
  if($feature.List) {
   $items=Get-PgsRegList $Hive $feature.List
   $lists+=[pscustomobject]@{Sub=$feature.List;Present=($null -ne $items);Items=$items}
  }
 }
 [pscustomobject]@{Format='PGS-v4';Computer=$env:COMPUTERNAME;Name=$User.Name;SID=$User.SID;When=(Get-Date).ToString('o');Values=$values;Lists=$lists}
}

function Get-PgsFeatureState([string]$Hive) {
 $state=[ordered]@{}
 foreach($entry in $PgsFeatures.GetEnumerator()) {
  $on=$true
  foreach($reg in $entry.Value.Regs) {
   $cur=Get-PgsRegValue $Hive $reg.Sub $reg.Name
   if($null -eq $cur -or "$($cur.Data)" -ne "$($reg.Data)"){$on=$false}
  }
  if($entry.Value.List) {
   $items=Get-PgsRegList $Hive $entry.Value.List
   if($null -eq $items -or $items.Count -eq 0){$on=$false}
  }
  $state[$entry.Key]=$on
 }
 $state
}

function Set-PgsFeatures([string]$Hive,[hashtable]$Desired,[string[]]$Blocked) {
 foreach($entry in $PgsFeatures.GetEnumerator()) {
  $on=[bool]$Desired[$entry.Key]
  foreach($reg in $entry.Value.Regs) {
   if($on){Set-PgsRegValue $Hive $reg.Sub $reg.Name 'DWord' $reg.Data}else{Remove-PgsRegValue $Hive $reg.Sub $reg.Name}
  }
  if($entry.Value.List) {
   Remove-PgsRegKey $Hive $entry.Value.List
   if($on){$i=0; foreach($app in $Blocked){$i++; Set-PgsRegValue $Hive $entry.Value.List ([string]$i) 'String' $app}}
  }
 }
}

# Converts a backup written by v3.0 into the v4 layout.
function Convert-PgsV3Backup($Old) {
 $map=@{HideDrives=@($PolExplorer,'NoDrives');TaskManager=@($PolSystem,'DisableTaskMgr');CommandPrompt=@($PolCmd,'DisableCMD')
        Settings=@($PolExplorer,'NoControlPanel');RunMenu=@($PolExplorer,'NoRun');ShellBlock=@($PolExplorer,'DisallowRun')}
 $values=@(foreach($v in @($Old.Values)){
  if($map.ContainsKey($v.Key)){
   $kind='DWord'; if($v.Type -eq 'SZ'){$kind='String'}
   [pscustomobject]@{Sub=$map[$v.Key][0];Name=$map[$v.Key][1];Present=[bool]$v.Present;Kind=$kind;Data=$v.Value}
  }
 })
 [pscustomobject]@{Format='PGS-v4';Computer=$Old.Computer;Name=$Old.Name;SID=$Old.SID;Values=$values
  Lists=@([pscustomobject]@{Sub="$PolExplorer\DisallowRun";Present=[bool]$Old.ListPresent;Items=$Old.List})}
}

function Restore-PgsSnapshot([string]$Hive,$Snap) {
 if($Snap.Format -eq 'PGS-v3'){$Snap=Convert-PgsV3Backup $Snap}
 foreach($v in @($Snap.Values)) {
  if($v.Present){Set-PgsRegValue $Hive $v.Sub $v.Name $v.Kind $v.Data}else{Remove-PgsRegValue $Hive $v.Sub $v.Name}
 }
 foreach($list in @($Snap.Lists)) {
  Remove-PgsRegKey $Hive $list.Sub
  if($list.Present) {
   [Microsoft.Win32.Registry]::Users.CreateSubKey("$Hive\$($list.Sub)").Dispose()
   if($list.Items){foreach($p in $list.Items.PSObject.Properties){Set-PgsRegValue $Hive $list.Sub $p.Name 'String' ([string]$p.Value)}}
  }
 }
}

function Initialize-PgsStore {
 if(-not (Test-Path -LiteralPath $PgsRoot)) {
  New-Item -ItemType Directory -Force -Path $PgsRoot | Out-Null
  # Backups describe other users' settings: only Administrators and SYSTEM may read them.
  [void](Invoke-PgsNative "$env:windir\System32\icacls.exe" @($PgsRoot,'/inheritance:r','/grant:r','*S-1-5-32-544:(OI)(CI)F','*S-1-5-18:(OI)(CI)F'))
 }
 New-Item -ItemType Directory -Force -Path $PgsBackupDir | Out-Null
}

function Save-PgsBackup($Snap,[string]$Reason) {
 Initialize-PgsStore
 $dir=Join-Path $PgsBackupDir $Snap.Name
 New-Item -ItemType Directory -Force -Path $dir | Out-Null
 $file=Join-Path $dir ('{0}-{1}-{2}.json' -f $Snap.Name,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$Reason)
 $Snap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding UTF8
 $check=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
 if($check.SID -ne $Snap.SID){throw "Backup file $file could not be verified. Nothing was changed."}
 $file
}

# Reads a user's current settings. Returns State (feature -> on/off) and the blocked program list.
function Invoke-PgsInspect([string]$Name) {
 $target=Get-PgsUser $Name
 Invoke-PgsWithHive $target {
  param($hive,$live)
  $items=Get-PgsRegList $hive $PgsFeatures['ShellBlock'].List
  $blockedNow=@(); if($items){$blockedNow=@($items.Values)}
  [pscustomobject]@{Name=$target.Name;SignedIn=$live;State=(Get-PgsFeatureState $hive);Blocked=$blockedNow}
 }
}

# Apply: $Desired maps feature names to $true/$false (missing = off). Clear: everything off.
# Restore: puts back the values saved in $BackupFile. Always saves a backup first.
function Invoke-PgsChange([string]$Name,[string]$Mode,[hashtable]$Desired=@{},[string[]]$Blocked=@(),[string]$BackupFile='') {
 if($Mode -notin @('Apply','Clear','Restore')){throw "Unknown mode $Mode."}
 $target=Get-PgsUser $Name
 $restoreFrom=$null
 if($Mode -eq 'Restore') {
  if(-not $BackupFile -or -not (Test-Path -LiteralPath $BackupFile)){throw "Backup file not found: $BackupFile"}
  $restoreFrom=Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
  if($restoreFrom.Format -notin @('PGS-v3','PGS-v4')){throw 'The selected file is not a PGS Kiosk Manager backup.'}
  if($restoreFrom.SID -ne $target.SID){throw "The selected backup belongs to '$($restoreFrom.Name)', not '$($target.Name)'."}
 }
 if($Mode -eq 'Apply' -and $Desired['ShellBlock'] -and @($Blocked).Count -eq 0){throw 'Program blocking is checked but the program list is empty.'}
 Invoke-PgsWithHive $target {
  param($hive,$live)
  $saved=Save-PgsBackup (Get-PgsSnapshot $hive $target) ('before-'+$Mode.ToLower())
  Write-PgsLog "$Mode $($target.Name) ($($target.SID)): backup $saved"
  "$($target.Name): backup saved to $saved"
  try {
   if($Mode -eq 'Apply'){Set-PgsFeatures $hive $Desired $Blocked}
   elseif($Mode -eq 'Clear'){Set-PgsFeatures $hive @{} @()}
   else{Restore-PgsSnapshot $hive $restoreFrom}
  } catch {
   Write-PgsLog "$Mode $($target.Name) FAILED: $($_.Exception.Message)"
   throw "$Mode failed for $($target.Name): $($_.Exception.Message) The settings from before are saved in $saved - use Restore with that file."
  }
  $state=Get-PgsFeatureState $hive
  $active=@($state.Keys | Where-Object {$state[$_]})
  $summary='none'; if($active.Count){$summary=$active -join ', '}
  Write-PgsLog "$Mode $($target.Name) done. Active: $summary"
  "$($target.Name): $Mode done. Active restrictions: $summary"
  if($live){"$($target.Name) is signed in right now: changes fully apply after they sign out and back in."}
 }
}

function Split-PgsList([string[]]$Items) {
 @($Items | ForEach-Object {$_ -split '[,;|\r\n]'} | ForEach-Object {$_.Trim()} | Where-Object {$_})
}

# ---- Command-line mode (skipped when the GUI dot-sources this file) ----
if($Action -ne 'Library') {
 $ErrorActionPreference='Stop'
 if(-not (Test-PgsAdmin)){Write-Output 'ERROR: Run this from an elevated (Run as administrator) PowerShell.'; exit 1}
 if($Action -eq 'Users'){Get-PgsUsers | Format-Table Name,SID,SignedIn,HasProfile -AutoSize | Out-String; exit 0}
 $names=Split-PgsList $UserName
 if($names.Count -eq 0){Write-Output 'ERROR: Specify -UserName.'; exit 1}
 $wanted=@{}
 foreach($k in (Split-PgsList $Enable)){
  if(-not $PgsFeatures.Contains($k)){Write-Output "ERROR: Unknown feature '$k'. Valid: $($PgsFeatures.Keys -join ', ')"; exit 1}
  $wanted[$k]=$true
 }
 $apps=Split-PgsList $BlockedApps
 if($apps.Count -eq 0){$apps=$PgsDefaultBlocked}
 $failed=$false
 foreach($n in $names) {
  try {
   if($Action -eq 'Inspect') {
    $r=Invoke-PgsInspect $n
    "$($r.Name)$(if($r.SignedIn){' (signed in)'})"
    foreach($e in $r.State.GetEnumerator()){'  {0,-14} {1}' -f $e.Key,$(if($e.Value){'ON'}else{'off'})}
    if($r.Blocked.Count){'  Blocked programs: '+($r.Blocked -join ', ')}
   } else {
    Invoke-PgsChange $n $Action $wanted $apps $BackupFile
   }
  } catch { "ERROR: $n : $($_.Exception.Message)"; $failed=$true }
 }
 if($failed){exit 1}
 exit 0
}
