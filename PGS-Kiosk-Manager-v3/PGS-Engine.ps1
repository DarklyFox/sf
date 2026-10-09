# PGS Kiosk Manager 3.0 - registry policy engine (Windows PowerShell 5.1)
# Target users MUST be signed out. No runtime/user changes outside selected local profiles.
param([ValidateSet('Inspect','Apply','Clear','Restore','Users')][string]$Action='Inspect',
      [string[]]$UserName=@(),[string]$Enable='', [string]$BackupFile='',[switch]$Confirm)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'PGS-Kiosk-Manager'; $backupDir=Join-Path $root 'Backups'
$explorer='Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$system='Software\Microsoft\Windows\CurrentVersion\Policies\System'
$cmdkey='Software\Policies\Microsoft\Windows\System'
$settings=[ordered]@{
 HideDrives=@{Sub=$explorer;Value='NoDrives';Data=67108863}
 TaskManager=@{Sub=$system;Value='DisableTaskMgr';Data=1}
 CommandPrompt=@{Sub=$cmdkey;Value='DisableCMD';Data=2}
 Settings=@{Sub=$explorer;Value='NoControlPanel';Data=1}
 RunMenu=@{Sub=$explorer;Value='NoRun';Data=1}
 ShellBlock=@{Sub=$explorer;Value='DisallowRun';Data=1}
}
$blocked=@('powershell.exe','powershell_ise.exe','pwsh.exe','cmd.exe','wt.exe','regedit.exe','reg.exe','mmc.exe')
function Reg([string[]]$parts,[switch]$AllowFailure) {
 $previous=$ErrorActionPreference; $ErrorActionPreference='Continue'
 try { $output=@(& "$env:windir\System32\reg.exe" @parts 2>&1 | ForEach-Object {"$_"}); $exit=$LASTEXITCODE }
 finally { $ErrorActionPreference=$previous }
 if($exit -ne 0 -and -not $AllowFailure){throw "Registry command failed ($exit): reg $($parts -join ' ')`n$($output -join "`n")"}
 return @{Exit=$exit;Lines=$output}
}
function ReadValue([string]$key,[string]$name) {
 $result=Reg @('query',$key,'/v',$name) -AllowFailure
 if($result.Exit -ne 0){return $null}
 foreach($line in $result.Lines){if($line -match '^\s*(\S+)\s+REG_(DWORD|SZ)\s+(.+?)\s*$' -and $Matches[1] -eq $name){
   return @{Type=$Matches[2];Value=$Matches[3].Trim()}
 }}
 return $null
}
function ReadList([string]$key) {
 $result=Reg @('query',$key) -AllowFailure
 if($result.Exit -ne 0){return $null}
 $out=[ordered]@{}
 foreach($line in $result.Lines){if($line -match '^\s*(\d+)\s+REG_SZ\s+(.+?)\s*$'){$out[$Matches[1]]=$Matches[2].Trim()}}
 return $out
}
function WriteValue([string]$key,[string]$name,[string]$type,[string]$value) {
 [void](Reg @('add',$key,'/v',$name,'/t',("REG_"+$type),'/d',$value,'/f'))
}
function DropValue([string]$key,[string]$name) {
 if($null -ne (ReadValue $key $name)){[void](Reg @('delete',$key,'/v',$name,'/f'))}
}
function GetUsers {
 $admins=@{}
 Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object {$admins[$_.SID.Value]=$true}
 @(Get-LocalUser | Where-Object {$_.Enabled -and -not $admins.ContainsKey($_.SID.Value) -and $_.SID.Value -notmatch '-500$'} | Sort-Object Name)
}
function WithHive($user,[scriptblock]$body) {
 $sid=$user.SID.Value
 if(Test-Path "Registry::HKEY_USERS\$sid"){throw "$($user.Name): User registry is loaded. Sign the user out completely."}
 $userProfile=Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid | Select-Object -First 1
 if(-not $userProfile -or -not $userProfile.LocalPath){throw "$($user.Name): Sign in once to create the Windows profile, then sign out."}
 $file=Join-Path $userProfile.LocalPath 'NTUSER.DAT'
 if(-not(Test-Path -LiteralPath $file)){throw "Missing $file"}
 $mount='PGS3_'+[guid]::NewGuid().ToString('N').Substring(0,12)
 $h='HKU\'+$mount
 [void](Reg @('load',$h,$file))
 try { & $body $h }
 finally {
  [gc]::Collect();[gc]::WaitForPendingFinalizers()
  $unload=Reg @('unload',$h) -AllowFailure
  if($unload.Exit -ne 0){Write-Warning "Could not unload $h. Do not delete it. Restart and contact IT. $($unload.Lines -join ' ')"}
 }
}
function Snapshot([string]$h,[string]$username,[string]$sid) {
 $values=@()
 foreach($item in $settings.GetEnumerator()) {
  $r=$item.Value;$found=ReadValue "$h\$($r.Sub)" $r.Value
  $values+=@{Key=$item.Key;Present=($null -ne $found);Type=$(if($found){$found.Type}else{''});Value=$(if($found){$found.Value}else{''})}
 }
 $list=ReadList "$h\$explorer\DisallowRun"
 return @{Format='PGS-v3';Computer=$env:COMPUTERNAME;Name=$username;SID=$sid;When=(Get-Date).ToString('o');Values=$values;ListPresent=($null -ne $list);List=$list}
}
function SaveSnapshot($snap) {
 New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
 $path=Join-Path $backupDir ("$($env:COMPUTERNAME)-$($snap.Name)-"+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')
 $snap|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $path -Encoding UTF8
 return $path
}
function RestoreSnapshot($h,$snap) {
 foreach($entry in $snap.Values) {
  if(-not $settings.Contains($entry.Key)){continue}
  $r=$settings[$entry.Key];$path="$h\$($r.Sub)"
  if($entry.Present){WriteValue $path $r.Value $entry.Type ([string]$entry.Value)}else{DropValue $path $r.Value}
 }
 $path="$h\$explorer\DisallowRun"; $existing=ReadList $path
 if($null -ne $existing){[void](Reg @('delete',$path,'/f'))}
 if($snap.ListPresent){
  [void](Reg @('add',$path,'/f'))
  if($snap.List){foreach($prop in $snap.List.PSObject.Properties){WriteValue $path $prop.Name 'SZ' ([string]$prop.Value)}}
 }
}
function IsPGSList($lst) {
 if($null -eq $lst){return $true}
 $vals=@($lst.Values)
 return (@($vals|Where-Object {$_ -notin $blocked}).Count -eq 0)
}
function HandleUser($user,$options) {
 WithHive $user {
  param($h)
  $old=Snapshot $h $user.Name $user.SID.Value
  if($Action -eq 'Inspect'){
   $old | ConvertTo-Json -Depth 12
   return
  }
  $backup=SaveSnapshot $old
  Write-Output "BACKUP: $backup"
  if($Action -eq 'Restore') {
   if(-not $BackupFile -or -not(Test-Path -LiteralPath $BackupFile)){throw 'Backup file missing.'}
   $snap=Get-Content -LiteralPath $BackupFile -Raw|ConvertFrom-Json
   if($snap.Format -ne 'PGS-v3' -or $snap.SID -ne $user.SID.Value -or $snap.Computer -ne $env:COMPUTERNAME){throw 'Backup version, machine or user SID mismatch.'}
   RestoreSnapshot $h $snap
  }else{
   $list=ReadList "$h\$explorer\DisallowRun"
   if(-not(IsPGSList $list)){throw 'Existing application-block list contains non-PGS entries. Left unchanged. Use restore from a verified backup or manual review.'}
   foreach($item in $settings.GetEnumerator()) {
    $r=$item.Value; $turnOn=($Action -eq 'Apply' -and $options.Contains($item.Key) -and [bool]$options[$item.Key])
    if($turnOn){WriteValue "$h\$($r.Sub)" $r.Value 'DWORD' ([string]$r.Data)}else{DropValue "$h\$($r.Sub)" $r.Value}
   }
   if($null -ne $list){[void](Reg @('delete',"$h\$explorer\DisallowRun",'/f'))}
   if($Action -eq 'Apply' -and $options.Contains('ShellBlock') -and $options['ShellBlock']){
    $path="$h\$explorer\DisallowRun";$i=0
    foreach($app in $blocked){$i++;WriteValue $path ([string]$i) 'SZ' $app}
   }
  }
  $actual=Snapshot $h $user.Name $user.SID.Value
  Write-Output ("RESULT: "+($actual|ConvertTo-Json -Compress -Depth 12))
 }
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as Administrator.'}
if($Action -eq 'Users'){$list=@(GetUsers|ForEach-Object {[pscustomobject]@{Name=$_.Name;SID=$_.SID.Value}})
 if($list.Count -eq 0){'[]'}else{ConvertTo-Json -InputObject $list}
 exit}
$UserName=@($UserName|ForEach-Object {$_ -split '\|'}|ForEach-Object {$_.Trim()}|Where-Object {$_})
if(-not $UserName -or $UserName.Count -eq 0){throw 'Specify at least one -UserName.'}
if($Action -in @('Apply','Clear','Restore') -and -not $Confirm){throw 'Use -Confirm for modifications.'}
$options=@{}
foreach($key in @($Enable -split '[,|]'|ForEach-Object {$_.Trim()}|Where-Object {$_})){
 if(-not $settings.Contains($key)){throw "Unknown option '$key'."}
 $options[$key]=$true
}
$users=@(GetUsers)
$failed=$false
foreach($name in $UserName){
 $user=$users|Where-Object Name -eq $name|Select-Object -First 1
 if(-not $user){Write-Output "ERROR: User $name not found or is an administrator.";$failed=$true;continue}
 try {HandleUser $user $options} catch {Write-Output "ERROR: $name : $_";$failed=$true}
}
if($failed){exit 1}
